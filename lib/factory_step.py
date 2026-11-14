#!/usr/bin/env python3
"""factory step runner: one model step through a standard CLI.

    FACTORY_PROVIDER=claude-code  claude -p (Claude Code CLI, stream-json)
    FACTORY_PROVIDER=opencode     opencode run, inside bin/opencode-acp-isolated (factory-oc + bwrap)

bin/factory-step calls this after it has scrubbed the environment and checked
the provider limit. Contract (kept from the DSH orchestrator it replaces):

  stderr  "factory: step start provider=... cwd=... timeoutMs=..."
          "factory: step end stopReason=<reason> exit=<code>"   (always, last)
  stdout  with --json: one JSON object {stopReason, output, text, ...}
          without: the final text
  exit    0 completed, 124 step timeout, 1 anything else

Claude Code records go to $FACTORY_CC_USAGE_FILE (JSONL): the init event,
the result event, and the hook records (lib/cc/hook.mjs). bin/factory-provider-state
classifies the result record for usage limits. No secret value is printed.
"""
import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(os.environ.get("FACTORY_ROOT") or Path(__file__).resolve().parents[1])
DEFAULT_TIMEOUT_MS = 30 * 60 * 1000
TIMEOUT_EXIT_CODE = 124
MAX_PROMPT_BYTES = 100_000  # Linux caps one argv string at 128 KiB.
CC_CHILD_UNSET = (
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "DEEPSEEK_API_KEY", "OPENCODE_GO_KEY", "OPENCODE_API_KEY",
    "OPENCODE_GO_API_KEY", "OPENCODE_ZEN_API_KEY", "FACTORY_OC_API_KEY", "FACTORY_OC_WORKSPACE", "FACTORY_OC_HOME",
    "FACTORY_CC_OAUTH_TOKEN",
)
RESULT_FIELDS = (
    "subtype", "is_error", "stop_reason", "terminal_reason", "num_turns", "duration_ms", "duration_api_ms",
    "total_cost_usd", "usage", "modelUsage", "api_error_status", "api_error", "api_error_origin", "session_id",
    "permission_denials",
)


def positive_number(value):
    if value is None or value == "":
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if number > 0 and number != float("inf") else None


def resolve_timeout_ms(config_ms, env):
    """Explicit step timeout wins, then the stall budget (minus a margin for the
    stall retry wrapper), then the configured value."""
    step_ms = positive_number(env.get("FACTORY_STEP_TIMEOUT_MS"))
    if step_ms is not None:
        return int(step_ms)
    stall_sec = positive_number(env.get("FACTORY_STALL_TIMEOUT_SEC"))
    if stall_sec is not None:
        ms = int(stall_sec * 1000)
        margin = max(60000, ms // 10)
        return max(ms - margin, ms // 2)
    configured = positive_number(config_ms)
    return int(configured) if configured is not None else DEFAULT_TIMEOUT_MS


def exit_code_for(completed, timed_out):
    if completed:
        return 0
    if timed_out:
        return TIMEOUT_EXIT_CODE
    return 1


def err(line):
    sys.stderr.write(line.rstrip("\n") + "\n")
    sys.stderr.flush()


def load_cc_config():
    path = Path(os.environ.get("FACTORY_CC_CONFIG") or ROOT / "config/claude-code.json")
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def progress(phase, detail):
    """Best-effort progress line (local log, optional agmsg). Never fails the step."""
    body = f"[factory] {phase}: {detail}"
    try:
        log_dir = Path(os.environ.get("FACTORY_AGMSG_LOG_DIR") or ROOT / "local/logs")
        log_dir.mkdir(parents=True, exist_ok=True)
        with open(log_dir / "agmsg-progress.log", "a", encoding="utf-8") as fh:
            fh.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} {body}\n")
    except OSError:
        pass
    team = os.environ.get("FACTORY_AGMSG_TEAM")
    if not team:
        return
    scripts = os.environ.get("FACTORY_AGMSG_SCRIPTS") or f"{os.environ.get('HOME', '')}/.agents/skills/agmsg/scripts"
    t0 = time.time()
    status = 1
    try:
        status = subprocess.run(
            ["bash", f"{scripts}/send.sh", team, os.environ.get("FACTORY_AGMSG_FROM", "factory"),
             os.environ.get("FACTORY_AGMSG_TO", "factory"), body, "--force"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60,
        ).returncode
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        subprocess.run(
            [str(ROOT / "bin/factory-usage"), "agmsg-send", "--duration-ms", str(int((time.time() - t0) * 1000)),
             "--exit", str(status)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60,
        )
    except (OSError, subprocess.SubprocessError):
        pass


def append_usage(entry):
    path = os.environ.get("FACTORY_CC_USAGE_FILE")
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError:
        pass


class Child:
    """A child in its own process group, with a step timeout that interrupts,
    then terminates, then kills the group."""

    def __init__(self, argv, env, cwd):
        self.proc = subprocess.Popen(
            argv, env=env, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True, text=True, encoding="utf-8", errors="replace", bufsize=1,
        )
        self.timed_out = False
        self.stderr_tail = []
        self._stderr_thread = threading.Thread(target=self._pump_stderr, daemon=True)
        self._stderr_thread.start()

    def _pump_stderr(self):
        for line in self.proc.stderr:
            sys.stderr.write(line)
            sys.stderr.flush()
            self.stderr_tail.append(line)
            del self.stderr_tail[:-40]

    def _signal(self, sig):
        try:
            os.killpg(self.proc.pid, sig)
        except (ProcessLookupError, PermissionError):
            pass

    def arm_timeout(self, timeout_ms):
        def fire():
            if self.proc.poll() is not None:
                # The CLI already exited; something it started still holds the pipe.
                self._signal(signal.SIGKILL)
                return
            self.timed_out = True
            err(f"factory: timeout after {timeout_ms}ms — stopping child")
            # SIGINT ends the turn; SIGTERM then SIGKILL if it does not exit.
            for sig, grace in ((signal.SIGINT, 15), (signal.SIGTERM, 10)):
                self._signal(sig)
                deadline = time.time() + grace
                while time.time() < deadline and self.proc.poll() is None:
                    time.sleep(0.2)
                if self.proc.poll() is not None:
                    break
            # Leftover processes in the group (tool commands) would hold stdout open.
            self._signal(signal.SIGKILL)
        timer = threading.Timer(timeout_ms / 1000.0, fire)
        timer.daemon = True
        timer.start()
        return timer

    def wait(self):
        rc = self.proc.wait()
        self._stderr_thread.join(timeout=5)
        return rc


def json_lines(stream):
    for line in stream:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            yield json.loads(line)
        except ValueError:
            continue


# ---------------------------------------------------------------- Claude Code
def cc_settings(hook):
    node = shutil.which("node") or "node"
    def cmd(mode):
        command = f"{shlex.quote(node)} {shlex.quote(str(hook))} {mode}"
        if mode == "pretooluse":
            # A crashed hook is a non-blocking error to Claude Code, which would let the tool run.
            # Exit 2 blocks the tool call, so any hook failure denies (fail closed).
            command += " || exit 2"
        return {"type": "command", "command": command}
    return {
        "hooks": {
            "PreToolUse": [{"matcher": "*", "hooks": [cmd("pretooluse")]}],
            "Stop": [{"hooks": [cmd("stop")]}],
            "StopFailure": [{"hooks": [cmd("stop-failure")]}],
        }
    }


def cc_child_env(cfg, cwd):
    env = dict(os.environ)
    token = env.get("FACTORY_CC_OAUTH_TOKEN") or env.get("CLAUDE_CODE_OAUTH_TOKEN")
    for name in CC_CHILD_UNSET:
        env.pop(name, None)
    env.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
    if token:
        env["CLAUDE_CODE_OAUTH_TOKEN"] = token
    # The pinned effort wins over --effort and any settings file (env > flag).
    env["CLAUDE_CODE_EFFORT_LEVEL"] = cfg["effort"]
    # Not CLAUDE_CODE_SUBPROCESS_ENV_SCRUB: on 2.1.319 it forces permission mode to
    # `default` and sandboxes Bash, so -p steps cannot edit (seen on the PC, 2026-11-14).
    env.pop("CLAUDE_CODE_SUBPROCESS_ENV_SCRUB", None)
    # The pinned version changes only through factory-update (approval).
    env["DISABLE_AUTOUPDATER"] = "1"
    env["DISABLE_UPDATES"] = "1"
    env["FACTORY_CC_CWD"] = cwd
    env["FACTORY_ROOT"] = str(ROOT)
    return env


def cc_argv(claude, cfg, task, settings_file, append_file, session_id):
    argv = [
        claude, "-p", task,
        "--output-format", "stream-json", "--verbose",
        "--model", cfg["model"],
        "--effort", cfg["effort"],
        "--permission-mode", cfg.get("permission_mode", "acceptEdits"),
        "--permission-prompts", "none",
        "--settings", settings_file,
        "--setting-sources", cfg.get("setting_sources", "user"),
        "--strict-mcp-config",
        "--session-id", session_id,
        f"--disallowedTools={cfg.get('disallowed_tools', 'AskUserQuestion,ExitPlanMode')}",
    ]
    if append_file:
        argv += ["--append-system-prompt-file", append_file]
    return argv


def run_claude(task, cwd, timeout_ms):
    cfg = load_cc_config()
    if cfg.get("permission_mode") == "bypassPermissions":
        raise RuntimeError("config/claude-code.json: bypassPermissions is not allowed")
    claude = os.environ.get("FACTORY_CLAUDE_BIN") or shutil.which("claude")
    if not claude:
        raise RuntimeError("claude CLI not found (run factory-setup)")
    step = os.environ.get("FACTORY_CC_STEP", "")
    tmp = Path(tempfile.mkdtemp(prefix="factory-cc-"))
    try:
        settings_file = tmp / "settings.json"
        settings_file.write_text(json.dumps(cc_settings(ROOT / "lib/cc/hook.mjs")))
        append_file = None
        if step:
            out = tmp / "append.md"
            p = subprocess.run(
                [shutil.which("node") or "node", str(ROOT / "lib/cc/pstack-session.js"), "render", step, str(out)],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60,
            )
            if p.returncode != 0:
                raise RuntimeError(f"pstack stage bootstrap failed: {p.stderr.strip()[-300:]}")
            if out.exists() and out.stat().st_size > 0:
                append_file = str(out)
        session_id = os.environ.get("FACTORY_CC_SESSION_ID") or str(uuid.uuid4())
        argv = cc_argv(claude, cfg, task, str(settings_file), append_file, session_id)
        err(f"factory: claude session={session_id} model={cfg['model']} effort={cfg['effort']} step={step or '-'}")
        child = Child(argv, cc_child_env(cfg, cwd), cwd)
        timer = child.arm_timeout(timeout_ms)
        result = None
        for event in json_lines(child.proc.stdout):
            etype, sub = event.get("type"), event.get("subtype")
            if etype == "system" and sub == "init":
                append_usage({"source": "claude-cli.init", "model": event.get("model"),
                              "effort": event.get("effort"), "claude_code_version": event.get("claude_code_version"),
                              "permissionMode": event.get("permissionMode"), "session_id": event.get("session_id")})
            elif etype == "system" and sub == "api_retry":
                append_usage({"source": "claude-cli.api_retry", "attempt": event.get("attempt"),
                              "error_status": event.get("error_status"), "error": event.get("error")})
            elif etype == "result":
                result = event
        rc = child.wait()
        timer.cancel()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    rec = {"source": "claude-cli.result", "type": "result", "exit_code": rc}
    if result:
        rec.update({k: result.get(k) for k in RESULT_FIELDS if k in result})
        if isinstance(result.get("result"), str):
            rec["result_head"] = result["result"][:300]
    else:
        rec["result_head"] = "".join(child.stderr_tail)[-300:] or None
    append_usage(rec)
    text = result.get("result") if result and isinstance(result.get("result"), str) else ""
    completed = (not child.timed_out and rc == 0 and result is not None
                 and result.get("subtype") == "success" and not result.get("is_error"))
    if completed:
        reason = "completed"
    elif child.timed_out:
        reason = "timeout"
    else:
        reason = (result or {}).get("subtype") or "error"
    payload = {"stopReason": reason, "output": [{"type": "text", "text": text}] if text else [], "text": text,
               "session_id": (result or {}).get("session_id") or session_id}
    for key in ("usage", "modelUsage", "total_cost_usd", "num_turns"):
        if result and key in result:
            payload[key] = result[key]
    if not completed:
        payload["diagnostic"] = (text or "".join(child.stderr_tail))[-500:] or f"claude exited {rc}"
    return payload, exit_code_for(completed, child.timed_out)


# ---------------------------------------------------------------- OpenCode
def oc_text(event):
    """Text from one `opencode run --format json` event. Accepts a part object
    either at the top level or under "part"."""
    for obj in (event, event.get("part") if isinstance(event.get("part"), dict) else None):
        if isinstance(obj, dict) and obj.get("type") == "text" and isinstance(obj.get("text"), str):
            return obj["text"]
    return None


def oc_error(event):
    if event.get("type") == "error" or (isinstance(event.get("error"), (dict, str)) and event.get("error")):
        e = event.get("error")
        if isinstance(e, dict):
            # Seen on opencode 2.2.7: {"type":"error","error":{"type":"provider.auth","message":...,"status":401}}
            msg = str(e.get("message") or e.get("name") or e)
            status = e.get("status")
            kind = e.get("type") or e.get("name")
            head = " ".join(str(x) for x in (status, kind) if x)
            return (f"{head}: {msg}" if head else msg)[:300]
        return str(e or event)[:300]
    return None


def run_opencode(task, cwd, timeout_ms):
    launcher = os.environ.get("FACTORY_OC_LAUNCHER") or str(ROOT / "bin/opencode-acp-isolated")
    argv = [launcher, "run", task]
    if os.environ.get("FACTORY_OC_LAUNCHER_NO_SUDO") != "1":
        argv = ["sudo", "-n"] + argv
    child = Child(argv, dict(os.environ), cwd)
    timer = child.arm_timeout(timeout_ms)
    texts, errors, raw_tail = [], [], []
    for event in json_lines(child.proc.stdout):
        t = oc_text(event)
        if t is not None:
            texts.append(t)
        e = oc_error(event)
        if e:
            errors.append(e)
        raw_tail.append(event.get("type"))
    rc = child.wait()
    timer.cancel()
    text = texts[-1] if texts else ""
    completed = not child.timed_out and rc == 0 and not errors
    reason = "completed" if completed else ("timeout" if child.timed_out else "error")
    payload = {"stopReason": reason, "output": [{"type": "text", "text": text}] if text else [], "text": text}
    if not completed:
        payload["diagnostic"] = ("; ".join(errors) or "".join(child.stderr_tail))[-500:] or f"opencode exited {rc}"
    return payload, exit_code_for(completed, child.timed_out)


# ---------------------------------------------------------------- main
def main(argv):
    json_out = False
    rest = []
    for a in argv:
        if a == "--json" and not rest:
            json_out = True
        else:
            rest.append(a)
    task = " ".join(rest)
    if task.strip() in ("", "-"):
        task = sys.stdin.read()
    provider = os.environ.get("FACTORY_PROVIDER", "claude-code")
    cwd = os.getcwd()
    cfg_timeout = None
    try:
        cfg_timeout = load_cc_config().get("timeoutMs")
    except (OSError, ValueError):
        pass
    timeout_ms = resolve_timeout_ms(cfg_timeout, os.environ)
    err(f"factory: step start provider={provider} cwd={cwd} timeoutMs={timeout_ms}")
    progress("start", f"provider={provider} cwd={cwd}")
    try:
        if not task.strip():
            raise RuntimeError("a task is required")
        if len(task.encode("utf-8")) > MAX_PROMPT_BYTES:
            raise RuntimeError(f"task is {len(task.encode('utf-8'))} bytes; the argv cap is {MAX_PROMPT_BYTES}")
        if task.startswith("-"):
            task = " " + task  # never parsed as a flag
        if provider == "claude-code":
            payload, code = run_claude(task, cwd, timeout_ms)
        elif provider == "opencode":
            payload, code = run_opencode(task, cwd, timeout_ms)
        else:
            raise RuntimeError(f"unknown provider {provider}")
    except Exception as e:  # noqa: BLE001 - every failure must still print the step-end line
        err(f"factory: step failed to run: {e}")
        payload, code = {"stopReason": "error", "output": [], "text": "", "diagnostic": str(e)[:500]}, 1
    err(f"factory: step end stopReason={payload['stopReason']} exit={code}")
    progress("end", f"stopReason={payload['stopReason']} exit={code}")
    if json_out:
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    elif payload.get("text"):
        t = payload["text"]
        sys.stdout.write(t if t.endswith("\n") else t + "\n")
    sys.stdout.flush()
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
