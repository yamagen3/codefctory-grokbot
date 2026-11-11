"""Factory usage tracking: per-step JSONL records + agmsg backlog metrics.

Storage: <FACTORY_USAGE_DIR or $FACTORY_ROOT/local/usage>/<YYYY-MM-DD>/{steps,agmsg,runs}.jsonl
One JSON object per line, append-only (O_APPEND writes < PIPE_BUF are atomic enough for
concurrent steps). Tokens are never invented: null + token_source="source_missing" when absent.
"""
import datetime as dt
import json
import os
import re
import subprocess
import time
from pathlib import Path

def _default_root() -> Path:
    env = os.environ.get("FACTORY_ROOT")
    if env:
        return Path(env)
    # lib/factory_usage.py → repo root. Original host: /workspace/factory.
    return Path(__file__).resolve().parents[1]


ROOT = _default_root()
STEPS = ("spec", "impl", "gate-claude", "gate-grok", "other")
PROVIDERS = ("claude-code", "opencode", "grok", "agmsg", "system")


def usage_dir():
    return Path(os.environ.get("FACTORY_USAGE_DIR", ROOT / "local/usage"))


def now_iso():
    return dt.datetime.now().astimezone().isoformat(timespec="milliseconds")


def append(kind, rec):
    d = usage_dir() / rec.get("started_at", rec.get("ts", now_iso()))[:10]
    d.mkdir(parents=True, exist_ok=True)
    line = json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n"
    fd = os.open(d / f"{kind}.jsonl", os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, line.encode())
    finally:
        os.close(fd)
    return d / f"{kind}.jsonl"


def read(kind, date=None):
    base = usage_dir()
    files = [base / date / f"{kind}.jsonl"] if date else sorted(base.glob(f"*/{kind}.jsonl"))
    out = []
    for f in files:
        if not f.exists():
            continue
        for l in f.read_text().splitlines():
            if l.strip():
                try:
                    out.append(json.loads(l))
                except json.JSONDecodeError:
                    pass
    return out


def _int(v):
    return v if isinstance(v, int) and not isinstance(v, bool) else None


def tokens_from_result(obj):
    """Usage from a DSH/CC/OpenCode result JSON. Accepts common shapes; returns (in, out, extra, source)."""
    if not isinstance(obj, dict):
        return None, None, {}, "source_missing"
    for key in ("usage", "tokenUsage", "tokens"):
        u = obj.get(key)
        if isinstance(u, dict):
            i = _int(u.get("input_tokens", u.get("inputTokens", u.get("input"))))
            o = _int(u.get("output_tokens", u.get("outputTokens", u.get("output"))))
            extra = {}
            for k_src, k_dst in (("cache_read_input_tokens", "cache_read_tokens"), ("cacheReadInputTokens", "cache_read_tokens"),
                                 ("cache_creation_input_tokens", "cache_write_tokens"), ("reasoning", "reasoning_tokens"),
                                 ("reasoning_tokens", "reasoning_tokens")):
                if _int(u.get(k_src)) is not None:
                    extra[k_dst] = u[k_src]
            if isinstance(u.get("cache"), dict):
                if _int(u["cache"].get("read")) is not None:
                    extra["cache_read_tokens"] = u["cache"]["read"]
                if _int(u["cache"].get("write")) is not None:
                    extra["cache_write_tokens"] = u["cache"]["write"]
            if i is not None or o is not None:
                return i, o, extra, f"result.{key}"
    return None, None, {}, "source_missing"


def tokens_from_cc_sidecar(text):
    """Claude Agent SDK result usage written by our dsh-subagent-claude-code patch (FACTORY_CC_USAGE_FILE).
    modelUsage (all model calls incl. subagents) is preferred; usage (main loop only) is the fallback."""
    extra = {}
    for l in (text or "").splitlines():
        try:
            j = json.loads(l)
        except json.JSONDecodeError:
            continue
        if isinstance(j, dict) and j.get("source") == "claude-agent-sdk.init":
            extra["cc_model"] = j.get("model")
            if j.get("effort") is not None or "cc_effort" not in extra:
                extra["cc_effort"] = j.get("effort")
        if isinstance(j, dict) and j.get("source") == "claude-agent-sdk.stop-hook" and j.get("effort") is not None:
            extra["cc_effort"] = j["effort"]  # effective level for the turn (post-downgrade)
    d = next((json.loads(l) for l in reversed((text or "").splitlines())
              if l.strip().startswith("{") and '"claude-agent-sdk.result"' in l), None)
    if not isinstance(d, dict):
        return None, None, extra, "source_missing"
    mu = d.get("modelUsage")
    if isinstance(d.get("total_cost_usd"), (int, float)):
        extra["cost_usd_estimate"] = d["total_cost_usd"]
    if isinstance(d.get("num_turns"), int):
        extra["num_turns"] = d["num_turns"]
    if isinstance(mu, dict) and mu:
        tot = lambda k: sum(v.get(k) or 0 for v in mu.values() if isinstance(v, dict))
        extra.update({"cache_read_tokens": tot("cacheReadInputTokens"), "cache_write_tokens": tot("cacheCreationInputTokens"),
                      "models": sorted(mu)})
        if any("thinkingTokens" in v for v in mu.values() if isinstance(v, dict)):
            extra["reasoning_tokens"] = tot("thinkingTokens")
        return tot("inputTokens"), tot("outputTokens"), extra, "cc-sdk-sidecar.modelUsage"
    i, o, ex, src = tokens_from_result({"usage": d.get("usage")})
    return i, o, {**extra, **ex}, ("cc-sdk-sidecar.usage" if src != "source_missing" else src)


def last_json_line(text):
    for l in reversed((text or "").strip().splitlines()):
        l = l.strip()
        if l.startswith("{"):
            try:
                return json.loads(l)
            except json.JSONDecodeError:
                continue
    return None


# ---- OpenCode: lifetime stats delta (DSH's ACP result carries no usage) ----
def oc_stats_home():
    """Shared /home/factory-oc, or the parallel slot home when FACTORY_OC_HOME is set.
    The launcher bind-mounts the slot home as /home/factory-oc inside bwrap, so that
    slot's stats DB is on the host at FACTORY_OC_HOME, not in the shared home.
    """
    return os.environ.get("FACTORY_OC_HOME") or "/home/factory-oc"


def oc_stats_argv():
    cmd = os.environ.get("FACTORY_USAGE_OC_STATS_CMD")
    if cmd:
        return ["bash", "-c", cmd]
    home = oc_stats_home()
    return ["sudo", "-n", "-u", "factory-oc", "env", f"HOME={home}",
            f"XDG_DATA_HOME={home}/.local/share", f"XDG_CONFIG_HOME={home}/.config",
            "/home/factory-oc/bin/opencode", "stats", "--all", "--json", "--standalone"]


def oc_stats():
    try:
        p = subprocess.run(oc_stats_argv(), capture_output=True, text=True, timeout=60, cwd="/tmp")
        d = json.loads(p.stdout)
        t = d["tokens"]
        return {"input": t.get("input"), "output": t.get("output"), "reasoning": t.get("reasoning"),
                "cache_read": (t.get("cache") or {}).get("read"), "prompts": d.get("prompts")}
    except Exception:
        return None


def _read_text_maybe_sudo(path: Path):
    try:
        if path.is_file() and os.access(path, os.R_OK):
            return path.read_text()
    except OSError:
        pass
    try:
        chk = subprocess.run(["sudo", "-n", "test", "-f", str(path)], capture_output=True, timeout=5)
        if chk.returncode != 0:
            return None
        p = subprocess.run(["sudo", "-n", "cat", str(path)], capture_output=True, text=True, timeout=5)
        if p.returncode == 0 and p.stdout.strip():
            return p.stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    return None


def oc_configured():
    """(model, reasoningEffort) from the OpenCode config this step used.
    Missing or unreadable config returns (None, None). Values are not invented.
    """
    raw = _read_text_maybe_sudo(Path(oc_stats_home()) / ".config/opencode/opencode.json")
    if not raw:
        return None, None
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError:
        return None, None
    model = doc.get("model") if isinstance(doc.get("model"), str) else None
    effort = None
    if isinstance(model, str) and "/" in model:
        provider, mid = model.split("/", 1)
        cur = doc.get("providers")
        for key in (provider, "models", mid, "settings", "reasoningEffort"):
            if not isinstance(cur, dict):
                cur = None
                break
            cur = cur.get(key)
        if isinstance(cur, str):
            effort = cur
    return model, effort


def normalize_step(raw):
    """Stable step label. Parallel IMPL slots are impl-sN; those stay step=impl plus a slot number."""
    if raw in STEPS:
        return raw, None
    if isinstance(raw, str):
        m = re.fullmatch(r"impl-s(\d+)", raw)
        if m:
            return "impl", int(m.group(1))
    return "other", None


def oc_delta(before, after):
    if not before or not after:
        return None
    return {k: (after[k] - before[k]) if isinstance(after.get(k), int) and isinstance(before.get(k), int) else None for k in after}


def record_step(provider, started_at, ended_at, duration_ms, exit_code, result_text="", oc_before=None, oc_after=None,
                notes=None, cc_usage_text="", **ctx):
    res = last_json_line(result_text)
    i, o, extra, src = tokens_from_result(res)
    note = list(notes or [])
    if provider == "claude-code" and cc_usage_text:
        ci, co, cextra, csrc = tokens_from_cc_sidecar(cc_usage_text)
        if src == "source_missing":
            i, o, extra, src = ci, co, cextra, csrc
        else:
            extra.update({k: v for k, v in cextra.items() if k in ("cc_model", "cc_effort")})
        want = os.environ.get("FACTORY_CC_EXPECT_EFFORT", "xhigh")
        if "cc_model" in cextra and cextra.get("cc_effort") is None:
            note.append("effort not reported by SDK init (unverified)")
        if cextra.get("cc_effort") and cextra["cc_effort"] != want:
            note.append(f"effort downgrade: requested {want}, effective {cextra['cc_effort']}")
    if src == "source_missing" and provider == "opencode":
        # A fresh slot home has no stats DB yet, so the before probe is null while after
        # has this slot's tokens. Treat that before as zero. The shared home does not:
        # a failed before there must not turn a lifetime total into this step's usage.
        if oc_before is None and isinstance(oc_after, dict) and os.environ.get("FACTORY_OC_HOME"):
            oc_before = {"input": 0, "output": 0, "reasoning": 0, "cache_read": 0, "prompts": 0}
            note.append("oc-stats before missing on slot home; delta from zero baseline")
        if oc_before is not None:
            dlt = oc_delta(oc_before, oc_after)
            if dlt and dlt.get("input") is not None:
                i, o, src = dlt["input"], dlt["output"], "opencode-stats-delta"
                if dlt.get("reasoning") is not None:
                    extra["reasoning_tokens"] = dlt["reasoning"]
                if dlt.get("cache_read") is not None:
                    extra["cache_read_tokens"] = dlt["cache_read"]
                if dlt.get("prompts") not in (None, 1):
                    note.append(f"oc-stats delta spans {dlt.get('prompts')} prompts (concurrent OpenCode steps?)")
    if provider == "opencode":
        oc_model, oc_effort = oc_configured()
        if oc_model:
            extra["oc_model"] = oc_model
        if oc_effort:
            extra["oc_reasoning_effort"] = oc_effort
    if src == "source_missing":
        note.append("source_missing: " + {"claude-code": "no SDK usage sidecar (patch missing or step failed before a result)",
                                           "opencode": "ACP result has no usage and opencode stats unavailable"}.get(provider, "no usage in result"))
    total = (i + o) if isinstance(i, int) and isinstance(o, int) else None
    raw_step = ctx.get("step")
    step, oc_slot = normalize_step(raw_step)
    rec = {
        "run_id": ctx.get("run_id") or None, "target": ctx.get("target") or None,
        "round": int(ctx["round"]) if str(ctx.get("round") or "").isdigit() else None,
        "step": step,
        "provider": provider, "started_at": started_at, "ended_at": ended_at, "duration_ms": duration_ms,
        "input_tokens": i, "output_tokens": o, "total_tokens": total, **extra, "token_source": src,
        "stop_reason": (res or {}).get("stopReason"), "exit_code": exit_code,
        "notes": "; ".join(note) or None,
    }
    if oc_slot is not None:
        rec["oc_slot"] = oc_slot
    if raw_step and step == "other" and raw_step not in STEPS:
        rec["notes"] = "; ".join(filter(None, [rec["notes"], f"step label={raw_step}"]))
    append("steps", rec)
    return rec


# ---- agmsg backlog ----
def agmsg_unread(team, agent):
    cmd = os.environ.get("FACTORY_AGMSG_UNREAD_CMD")
    scripts = os.environ.get("FACTORY_AGMSG_SCRIPTS", str(Path.home() / ".agents/skills/agmsg/scripts"))
    # Read-only: storage_list_unread lists rows without marking them read (check-inbox.sh would mark them).
    script = cmd or (f'S="{scripts}"; SCRIPT_DIR="$S"; source "$S/lib/compat.sh" && source "$S/lib/storage.sh" && '
                     f'storage_list_unread "$1" "$2" | grep -c . || true')
    try:
        p = subprocess.run(["bash", "-c", script, "unread", team, agent], capture_output=True, text=True, timeout=30)
        v = p.stdout.strip().splitlines()[-1] if p.stdout.strip() else ""
        return int(v) if v.isdigit() else None
    except Exception:
        return None


def agmsg_poll(phase, **ctx):
    team = os.environ.get("FACTORY_AGMSG_TEAM")
    if not team:
        return []
    agents = [a for a in os.environ.get("FACTORY_AGMSG_POLL_AGENTS", os.environ.get("FACTORY_AGMSG_TO", "factory")).split(",") if a]
    out = []
    for a in agents:
        t0 = time.monotonic()
        n = agmsg_unread(team, a)
        rec = {"ts": now_iso(), "event": "poll", "phase": phase, "team": team, "agent": a, "unread": n,
               "poll_ms": int((time.monotonic() - t0) * 1000), "run_id": ctx.get("run_id"), "step": ctx.get("step"),
               "notes": None if n is not None else "unread probe failed"}
        append("agmsg", rec)
        out.append(rec)
    return out


def agmsg_report(date=None):
    ev = read("agmsg", date)
    sends = [e for e in ev if e.get("event") == "send"]
    polls = sorted([e for e in ev if e.get("event") == "poll"], key=lambda e: e["ts"])
    rep = {"send_count": len(sends), "send_ok": sum(1 for s in sends if s.get("exit_code") == 0),
           "send_duration_ms_total": sum(s.get("duration_ms") or 0 for s in sends),
           "send_duration_ms_max": max([s.get("duration_ms") or 0 for s in sends], default=None), "agents": {}}
    for p in polls:
        a = rep["agents"].setdefault(f"{p['team']}/{p['agent']}", {"polls": 0, "backlog_peak": None, "last_unread": None,
                                                                      "catchups": [], "_since": None})
        a["polls"] += 1
        n = p.get("unread")
        if n is None:
            continue
        a["backlog_peak"] = n if a["backlog_peak"] is None else max(a["backlog_peak"], n)
        a["last_unread"] = n
        ts = dt.datetime.fromisoformat(p["ts"])
        if n > 0 and a["_since"] is None:
            a["_since"] = ts
        elif n == 0 and a["_since"] is not None:
            a["catchups"].append(int((ts - a["_since"]).total_seconds() * 1000))
            a["_since"] = None
    for a in rep["agents"].values():
        a["catchup_duration_ms_max"] = max(a["catchups"], default=None)
        a["still_backlogged_since"] = a.pop("_since").isoformat() if a["_since"] else None
    # per-step before/after pairs
    pairs = {}
    for p in polls:
        if p.get("run_id") or p.get("step"):
            k = (p.get("run_id"), p.get("step"), p["agent"])
            pairs.setdefault(k, {})[p["phase"]] = p.get("unread")
    rep["steps"] = [{"run_id": k[0], "step": k[1], "agent": k[2], "unread_before": v.get("before"), "unread_after": v.get("after")}
                    for k, v in pairs.items()]
    return rep


# ---- aggregation ----
def summarize(recs, by):
    agg = {}
    for r in recs:
        key = tuple((r.get("started_at") or "")[:10] if b == "day" else r.get(b) for b in by)
        a = agg.setdefault(key, {"steps": 0, "duration_ms": 0, "input_tokens": 0, "output_tokens": 0, "total_tokens": 0,
                                 "steps_tokens_missing": 0, "failures": 0})
        a["steps"] += 1
        a["duration_ms"] += r.get("duration_ms") or 0
        if r.get("total_tokens") is None:
            a["steps_tokens_missing"] += 1
        for k in ("input_tokens", "output_tokens", "total_tokens"):
            a[k] += r.get(k) or 0
        if r.get("exit_code") not in (0, None):
            a["failures"] += 1
    return agg


def fmt_ms(ms):
    s = int((ms or 0) / 1000)
    return f"{s // 3600}h{s % 3600 // 60:02d}m{s % 60:02d}s" if s >= 3600 else f"{s // 60}m{s % 60:02d}s"


def table(agg, by):
    hdr = list(by) + ["steps", "wall", "in_tok", "out_tok", "total_tok", "tok_missing", "fail"]
    rows = [hdr]
    for k in sorted(agg, key=lambda k: tuple(str(x) for x in k)):
        a = agg[k]
        na = a["steps_tokens_missing"] == a["steps"]  # nothing known: print n/a, not a fake 0
        tk = lambda v: "n/a" if na else f"{v:,}"
        rows.append([str(x) for x in k] + [str(a["steps"]), fmt_ms(a["duration_ms"]), tk(a["input_tokens"]),
                                           tk(a["output_tokens"]), tk(a["total_tokens"]), str(a["steps_tokens_missing"]),
                                           str(a["failures"])])
    w = [max(len(r[i]) for r in rows) for i in range(len(hdr))]
    return "\n".join("  ".join(c.ljust(w[i]) for i, c in enumerate(r)) for r in rows)


def run_summary(run_id, wall_ms=None, status=None):
    recs = [r for r in read("steps") if r.get("run_id") == run_id]
    agg = summarize(recs, ("provider",))
    starts = [r["started_at"] for r in recs if r.get("started_at")]
    ends = [r["ended_at"] for r in recs if r.get("ended_at")]
    if wall_ms is None and starts and ends:
        wall_ms = int((dt.datetime.fromisoformat(max(ends)) - dt.datetime.fromisoformat(min(starts))).total_seconds() * 1000)
    target = next((r["target"] for r in recs if r.get("target")), None)
    summ = {"ts": now_iso(), "run_id": run_id, "target": target, "status": status, "wall_ms": wall_ms,
            "rounds": max([r["round"] for r in recs if r.get("round")], default=None),
            "by_provider": {k[0]: v for k, v in agg.items()}}
    append("runs", summ)
    lines = [f"usage run={run_id} target={target} status={status} wall={fmt_ms(wall_ms)} rounds={summ['rounds']}",
             table(agg, ("provider",))]
    text = "\n".join(lines) + "\n"
    out = usage_dir() / "runs"
    out.mkdir(parents=True, exist_ok=True)
    (out / f"{run_id}.md").write_text("```\n" + text + "```\n")
    return text


# ---- OpenCode Go subscription meters (official OpenCode Go endpoint; key never printed) ----
OCGO_URL = "https://opencode.ai/zen/go/v1/usage"
JST = dt.timezone(dt.timedelta(hours=9), "JST")


def ocgo_balance():
    """Returns {"ok": bool, "windows": {name: {status, percent, remaining_percent, resets_at_jst}}, "error": str|None}.
    Percent comes only from the server; missing/non-numeric percent -> remaining null (never invented)."""
    import urllib.error
    import urllib.request
    key = os.environ.get("OPENCODE_GO_KEY")
    rec = {"ts": now_iso(), "provider": "opencode-go", "ok": False, "windows": {}, "error": None}
    if not key:
        rec["error"] = "OPENCODE_GO_KEY not set"
        return rec
    url = os.environ.get("FACTORY_OCGO_USAGE_URL", OCGO_URL)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}", "Accept": "application/json",
                                               "User-Agent": "factory-usage"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            body = json.load(r)
    except urllib.error.HTTPError as e:
        rec["error"] = f"HTTP {e.code}"
        return rec
    except Exception as e:  # network, JSON
        rec["error"] = f"{type(e).__name__}: {str(e).replace(key, '***')[:200]}"
        return rec
    usage = body.get("usage") if isinstance(body, dict) else None
    if not isinstance(usage, dict):
        rec["error"] = "unexpected response shape (no usage object)"
        return rec
    for name, w in usage.items():
        if not isinstance(w, dict):
            continue
        p = w.get("percent")
        pct = p if isinstance(p, (int, float)) and not isinstance(p, bool) else None
        ra = w.get("resetsAt")
        try:
            jst = dt.datetime.fromisoformat(ra.replace("Z", "+00:00")).astimezone(JST).isoformat(timespec="minutes") if ra else None
        except (ValueError, AttributeError):
            jst = None
        rec["windows"][name] = {"status": w.get("status"), "percent": pct,
                                "remaining_percent": (round(100 - pct, 2) if pct is not None else None),
                                "resets_at": ra, "resets_at_jst": jst}
    rec["ok"] = bool(rec["windows"])
    if not rec["ok"]:
        rec["error"] = "no usage windows in response"
    return rec


def format_balance(rec):
    L = [f"OpenCode Go usage ({rec['ts'][:16]} JST)"]
    if not rec["ok"]:
        L.append(f"  UNAVAILABLE: {rec['error']}")
    for name, w in rec["windows"].items():
        rem = "unknown" if w["remaining_percent"] is None else f"{w['remaining_percent']:g}%"
        used = "?" if w["percent"] is None else f"{w['percent']:g}%"
        L.append(f"  {name:8} remaining {rem:>7}  (used {used}, status {w['status']})  resets {w['resets_at_jst'] or '?'}")
    L.append("Claude Code: remaining quota not shown (no official API; see DECISIONS.md)")
    return "\n".join(L)
