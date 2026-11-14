#!/usr/bin/env bash
# factory-usage: token parsing, null-not-invented, OpenCode stats delta, factory-step hook (fake dsh),
# agmsg send/unread backlog (fake unread probe), summaries. No model calls.
set -euo pipefail
F="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d /tmp/factory-usage-test-XXXXXX); trap 'rm -rf "$T"' EXIT
export FACTORY_USAGE_DIR="$T/usage"
U="$F/bin/factory-usage"
fail=0; t() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
q() { python3 -c "import json,glob,sys; r=[json.loads(l) for f in sorted(glob.glob('$T/usage/*/$1.jsonl')) for l in open(f)]; print(eval(sys.argv[1]))" "$2"; }
NOW=$(date -Iseconds)

# 1) CC result with SDK-style usage
echo '{"stopReason":"completed","text":"pong","usage":{"input_tokens":120,"output_tokens":8,"cache_read_input_tokens":900}}' > "$T/r1"
FACTORY_USAGE_RUN_ID=run-a FACTORY_TARGET_NAME=csv2md FACTORY_USAGE_ROUND=1 FACTORY_USAGE_STEP=spec \
  "$U" record-step --provider claude-code --started "$NOW" --ended "$NOW" --duration-ms 4000 --exit 0 --result-file "$T/r1"
t "usage parsed" "[ \"\$(q steps 'r[-1][\"input_tokens\"],r[-1][\"output_tokens\"],r[-1][\"total_tokens\"],r[-1][\"cache_read_tokens\"],r[-1][\"token_source\"]')\" = \"(120, 8, 128, 900, 'result.usage')\" ]"

# 2) current DSH shape (no usage) -> null + source_missing, never invented
echo '{"stopReason":"completed","output":[],"text":"pong"}' > "$T/r2"
FACTORY_USAGE_RUN_ID=run-a FACTORY_USAGE_STEP=gate-claude "$U" record-step --provider claude-code --started "$NOW" --ended "$NOW" --duration-ms 3000 --exit 0 --result-file "$T/r2"
t "missing -> null" "[ \"\$(q steps 'r[-1][\"total_tokens\"],r[-1][\"token_source\"],r[-1][\"notes\"].startswith(\"source_missing\")')\" = \"(None, 'source_missing', True)\" ]"

# 3) OpenCode: stats delta
FACTORY_USAGE_RUN_ID=run-a FACTORY_USAGE_STEP=impl FACTORY_USAGE_ROUND=1 "$U" record-step --provider opencode --started "$NOW" --ended "$NOW" \
  --duration-ms 60000 --exit 0 --result-file "$T/r2" \
  --oc-before '{"input":1000,"output":100,"reasoning":10,"cache_read":5000,"prompts":7}' \
  --oc-after  '{"input":1500,"output":160,"reasoning":30,"cache_read":9000,"prompts":8}'
t "oc delta" "[ \"\$(q steps 'r[-1][\"input_tokens\"],r[-1][\"output_tokens\"],r[-1][\"reasoning_tokens\"],r[-1][\"token_source\"]')\" = \"(500, 60, 20, 'opencode-stats-delta')\" ]"

# 4) factory-step hook end-to-end with a fake runner (stdout + exit code untouched)
cat > "$T/dsh" <<'D'
#!/usr/bin/env bash
echo '{"stopReason":"completed","output":[],"text":"pong","usage":{"input_tokens":7,"output_tokens":1}}'
exit ${FAKE_DSH_EXIT:-0}
D
chmod +x "$T/dsh"
out=$(FACTORY_STEP_RUNNER="$T/dsh" FACTORY_USAGE_RUN_ID=run-b FACTORY_USAGE_STEP=other "$F/bin/factory-step" --json hi)
t "step stdout passthrough" "echo '$out' | grep -q '\"text\":\"pong\"'"
t "step recorded" "[ \"\$(q steps '[x[\"total_tokens\"] for x in r if x[\"run_id\"]==\"run-b\"]')\" = '[8]' ]"
set +e; FAKE_DSH_EXIT=3 FACTORY_STEP_RUNNER="$T/dsh" FACTORY_USAGE_RUN_ID=run-c "$F/bin/factory-step" --json hi >/dev/null; ec=$?; set -e
t "exit code passthrough" "[ $ec -eq 3 ] && [ \"\$(q steps '[x[\"exit_code\"] for x in r if x[\"run_id\"]==\"run-c\"]')\" = '[3]' ]"

# 4b) CC usage sidecar (written by lib/factory_step.py): fake runner writes the claude -p result shape
cat > "$T/dsh-cc" <<'D'
#!/usr/bin/env bash
[ -n "${FACTORY_CC_USAGE_FILE:-}" ] && echo '{"source":"claude-cli.init","model":"claude-opus-5-5","effort":null}' >> "$FACTORY_CC_USAGE_FILE"
[ -n "${FACTORY_CC_USAGE_FILE:-}" ] && echo '{"source":"claude-cli.stop-hook","effort":"'"${FAKE_EFFORT:-xhigh}"'"}' >> "$FACTORY_CC_USAGE_FILE"
[ -n "${FACTORY_CC_USAGE_FILE:-}" ] && echo '{"source":"claude-cli.result","subtype":"success","num_turns":1,"total_cost_usd":0.0123,"usage":{"input_tokens":3,"output_tokens":5},"modelUsage":{"claude-x":{"inputTokens":10,"outputTokens":4,"cacheReadInputTokens":100,"cacheCreationInputTokens":50,"costUSD":0.01},"claude-y":{"inputTokens":2,"outputTokens":1,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"costUSD":0.0023}}}' >> "$FACTORY_CC_USAGE_FILE"
echo '{"stopReason":"completed","output":[],"text":"pong"}'
D
chmod +x "$T/dsh-cc"
FACTORY_STEP_RUNNER="$T/dsh-cc" FACTORY_USAGE_RUN_ID=run-cc "$F/bin/factory-step" --json hi >/dev/null
t "cc sidecar modelUsage summed" "[ \"\$(q steps '[(x[\"input_tokens\"],x[\"output_tokens\"],x[\"total_tokens\"],x[\"cache_read_tokens\"],x[\"cache_write_tokens\"],x[\"cost_usd_estimate\"],x[\"token_source\"]) for x in r if x[\"run_id\"]==\"run-cc\"]')\" = \"[(12, 5, 17, 100, 50, 0.0123, 'cc-sidecar.modelUsage')]\" ]"
t "init model/effort recorded" "[ \"\$(q steps '[(x[\"cc_model\"],x[\"cc_effort\"],x[\"notes\"]) for x in r if x[\"run_id\"]==\"run-cc\"]')\" = \"[('claude-opus-5-5', 'xhigh', None)]\" ]"
FAKE_EFFORT=high FACTORY_STEP_RUNNER="$T/dsh-cc" FACTORY_USAGE_RUN_ID=run-cc-dg "$F/bin/factory-step" --json hi >/dev/null
t "silent effort downgrade flagged" "q steps '[x[\"notes\"] for x in r if x[\"run_id\"]==\"run-cc-dg\"]' | grep -q 'effort downgrade: requested xhigh, effective high'"
# sidecar absent (patch missing) -> still null, never invented
FACTORY_STEP_RUNNER="$T/dsh" FACTORY_USAGE_RUN_ID=run-cc2 "$F/bin/factory-step" --json hi >/dev/null
t "no sidecar + no usage -> stays from result only" "[ \"\$(q steps '[x[\"token_source\"] for x in r if x[\"run_id\"]==\"run-cc2\"]')\" = \"['result.usage']\" ]"
echo '{"stopReason":"completed","output":[],"text":"x"}' > "$T/r3"
"$U" record-step --provider claude-code --started "$NOW" --ended "$NOW" --duration-ms 1 --exit 1 --result-file "$T/r3" --cc-usage-file "$T/nonexistent"
t "missing sidecar file -> null" "[ \"\$(q steps 'r[-1][\"total_tokens\"],r[-1][\"token_source\"]')\" = \"(None, 'source_missing')\" ]"

# 5) agmsg: sends + unread polls with a fake probe (0 -> 3 -> 5 -> 0)
printf '0\n3\n5\n0\n' > "$T/seq"
export FACTORY_AGMSG_TEAM=demo FACTORY_AGMSG_POLL_AGENTS=lead FACTORY_AGMSG_UNREAD_CMD="n=\$(head -1 $T/seq); sed -i 1d $T/seq; echo \$n"
for ph in before after before after; do FACTORY_USAGE_RUN_ID=run-a FACTORY_USAGE_STEP=impl "$U" agmsg-poll $ph; sleep 0.05; done
"$U" agmsg-send --duration-ms 120 --exit 0; "$U" agmsg-send --duration-ms 80 --exit 1
rep=$("$U" agmsg --json)
t "agmsg peak/catchup" "echo '$rep' | python3 -c 'import json,sys; d=json.load(sys.stdin); a=d[\"agents\"][\"demo/lead\"]; assert a[\"backlog_peak\"]==5 and a[\"catchup_duration_ms_max\"]>0 and d[\"send_count\"]==2 and d[\"send_ok\"]==1 and d[\"send_duration_ms_total\"]==200'"
FACTORY_AGMSG_UNREAD_CMD='exit 9' "$U" agmsg-poll before
t "agmsg probe failure -> null, no error" "[ \"\$(q agmsg 'r[-1][\"unread\"]')\" = None ]"
unset FACTORY_AGMSG_TEAM FACTORY_AGMSG_UNREAD_CMD

# 6) summaries
s=$("$U" summary --by provider,step)
t "summary rows" "echo \"\$s\" | grep -q '^opencode' && echo \"\$s\" | grep -q 'claude-code'"
rs=$("$U" run-summary run-a --status merged --print)
t "run summary" "echo \"\$rs\" | grep -q 'usage run=run-a target=csv2md status=merged' && [ -f $T/usage/runs/run-a.md ]"
t "show filter" "[ \$(\"$U\" show --run run-a | wc -l) -eq 3 ]"

# 7) parallel IMPL slots are step=impl (not other), and carry the slot plus OC model/effort
SLOT="$T/oc-home"
mkdir -p "$SLOT/.config/opencode"
cat > "$SLOT/.config/opencode/opencode.json" <<'JSON'
{"model":"opencode-go/deepseek-v4.1-flash","providers":{"opencode-go":{"models":{"deepseek-v4.1-flash":{"settings":{"reasoningEffort":"max"}}}}}}
JSON
FACTORY_OC_HOME="$SLOT" FACTORY_USAGE_RUN_ID=run-ocslot FACTORY_USAGE_STEP=impl-s2 \
  "$U" record-step --provider opencode --started "$NOW" --ended "$NOW" --duration-ms 10 --exit 0 \
  --result-file "$T/r2" --oc-before null \
  --oc-after '{"input":11,"output":4,"reasoning":3,"cache_read":1,"prompts":1}'
t "impl-sN is step impl" "[ \"\$(q steps '[(x[\"step\"], x.get(\"oc_slot\"), x[\"input_tokens\"], x[\"token_source\"], x.get(\"oc_model\"), x.get(\"oc_reasoning_effort\")) for x in r if x[\"run_id\"]==\"run-ocslot\"]')\" = \"[('impl', 2, 11, 'opencode-stats-delta', 'opencode-go/deepseek-v4.1-flash', 'max')]\" ]"
# shared-home before=None must stay source_missing (do not treat a lifetime DB as this step)
FACTORY_USAGE_RUN_ID=run-ocshared FACTORY_USAGE_STEP=impl \
  "$U" record-step --provider opencode --started "$NOW" --ended "$NOW" --duration-ms 10 --exit 0 \
  --result-file "$T/r2" --oc-after '{"input":99,"output":1,"reasoning":0,"cache_read":0,"prompts":1}'
t "shared home does not zero-baseline" "[ \"\$(q steps '[x[\"token_source\"] for x in r if x[\"run_id\"]==\"run-ocshared\"]')\" = \"['source_missing']\" ]"
python3 - <<PY
import os, sys
sys.path.insert(0, "$F/lib")
os.environ["FACTORY_OC_HOME"] = "$SLOT"
os.environ.pop("FACTORY_USAGE_OC_STATS_CMD", None)
import factory_usage as U
argv = U.oc_stats_argv()
joined = " ".join(argv)
assert "HOME=$SLOT" in joined, argv
assert "XDG_DATA_HOME=$SLOT/.local/share" in joined, argv
os.environ.pop("FACTORY_OC_HOME", None)
shared = " ".join(U.oc_stats_argv())
assert "HOME=/home/factory-oc" in shared, shared
print("oc-stats argv ok")
PY

# 8) plugin load failure: dsh exit 0, empty stdout, warning on stderr → factory-step non-zero
cat > "$T/dsh-noload" <<'D'
#!/usr/bin/env bash
echo "warning: Cannot find module '@deepseek-ai/schemastery'" >&2
exit 0
D
chmod +x "$T/dsh-noload"
set +e
FACTORY_STEP_RUNNER="$T/dsh-noload" FACTORY_USAGE_RUN_ID=run-noload "$F/bin/factory-step" --json hi >"$T/noload.out" 2>"$T/noload.err"
ec=$?
set -e
t "plugin load failure exits non-zero" "[ $ec -ne 0 ] && [ ! -s $T/noload.out ] && grep -q 'failed to load or run' $T/noload.err && grep -q schemastery $T/noload.err"

[ $fail -eq 0 ] && # sidecar modelUsage beats the runner payload's main-loop usage (claude -p result in both)
python3 - "$F" <<'PY'
import json, os, sys, tempfile
sys.path.insert(0, sys.argv[1] + "/lib")
os.environ["FACTORY_USAGE_DIR"] = tempfile.mkdtemp()
import factory_usage as U
payload = json.dumps({"stopReason": "completed", "usage": {"input_tokens": 1, "output_tokens": 2}})
side = "\n".join(json.dumps(x) for x in (
    {"source": "claude-cli.init", "model": "claude-opus-5-5"},
    {"source": "claude-cli.stop-hook", "effort": "xhigh"},
    {"source": "claude-cli.result", "type": "result", "num_turns": 7, "total_cost_usd": 0.5,
     "modelUsage": {"claude-opus-5-5": {"inputTokens": 10, "outputTokens": 20}, "claude-haiku": {"inputTokens": 3, "outputTokens": 4}}}))
i, o, extra, src = U.tokens_from_result(json.loads(payload))
assert src == "result.usage"
ci, co, cextra, csrc = U.tokens_from_cc_sidecar(side)
assert (ci, co, csrc) == (13, 24, "cc-sidecar.modelUsage") and cextra["num_turns"] == 7 and cextra["cc_effort"] == "xhigh", (ci, co, csrc, cextra)
U.record_step("claude-code", U.now_iso(), U.now_iso(), 5, 0, payload, cc_usage_text=side, run_id="pref", step="spec")
rows = [json.loads(l) for f in U.usage_dir().glob("*/steps.jsonl") for l in open(f)]
r = [x for x in rows if x.get("run_id") == "pref"][-1]
assert r["token_source"] == "cc-sidecar.modelUsage" and r["input_tokens"] == 13 and r["cc_effort"] == "xhigh", r
assert r.get("num_turns") == 7 and r.get("cost_usd_estimate") == 0.5, r
PY
echo "PASS sidecar modelUsage preferred over payload usage"
echo "test_factory_usage: PASS" || { echo "test_factory_usage: FAIL"; exit 1; }
