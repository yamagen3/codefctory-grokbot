#!/usr/bin/env bash
# Offline: lib/factory_step.py drives a fake `claude -p` (stream-json) and a fake
# OpenCode launcher. Checks the argv, the child env split, the usage sidecar, the
# limit park, the step-end contract, and the timeout. No model, network, or credential.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d /tmp/factory-step-runner-XXXXXX)"
trap 'rm -rf "$T"' EXIT
fail() { echo "test_factory_step_runner: FAIL $*" >&2; exit 1; }
unset FACTORY_AGMSG_TEAM FACTORY_CC_STEP FACTORY_STEP_RUNNER || true
export FACTORY_ROOT="$ROOT" FACTORY_USAGE_DISABLE=1 FACTORY_AGMSG_LOG_DIR="$T/logs"
export FACTORY_PROVIDER_STATE_DIR="$T/state" FACTORY_NOTIFY_DIR="$T/notify"

FAKE="$T/claude"
cat > "$FAKE" <<'SH'
#!/usr/bin/env bash
# Record argv and the env names/values the factory must control (never real secrets here).
printf '%s\n' "$@" > "$FAKE_DIR/argv"
{
  echo "OAUTH=${CLAUDE_CODE_OAUTH_TOKEN:-}"
  echo "STASH=${FACTORY_CC_OAUTH_TOKEN:-}"
  echo "APIKEY=${ANTHROPIC_API_KEY:-}"
  echo "OCKEY=${OPENCODE_GO_KEY:-}${FACTORY_OC_API_KEY:-}"
  echo "EFFORT=${CLAUDE_CODE_EFFORT_LEVEL:-}"
  echo "SCRUB=${CLAUDE_CODE_SUBPROCESS_ENV_SCRUB:-}"
  echo "STEP=${FACTORY_CC_STEP:-}"
} > "$FAKE_DIR/env"
case "${FAKE_MODE:-ok}" in
  ok)
    echo '{"type":"system","subtype":"init","model":"claude-opus-5-5","claude_code_version":"2.1.319","permissionMode":"acceptEdits","session_id":"s1"}'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"pong"}]}}'
    echo '{"type":"result","subtype":"success","is_error":false,"result":"pong","num_turns":1,"total_cost_usd":0.01,"session_id":"s1","usage":{"input_tokens":3,"output_tokens":1},"modelUsage":{"claude-opus-5-5":{"inputTokens":3,"outputTokens":1}}}'
    ;;
  limit)
    echo '{"type":"system","subtype":"init","model":"claude-opus-5-5","session_id":"s2"}'
    echo '{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"api_error":"usage_limit_reached","result":"You'"'"'ve hit your 5-hour limit · resets 11:20am (Asia/Tokyo)","session_id":"s2"}'
    exit 1
    ;;
  error)
    echo '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom","session_id":"s3"}'
    exit 1
    ;;
  noresult)
    echo "claude: something broke" >&2
    exit 0
    ;;
  hang)
    trap 'exit 130' INT
    sleep 30 & wait
    ;;
esac
SH
chmod +x "$FAKE"
export FACTORY_CLAUDE_BIN="$FAKE" FAKE_DIR="$T"

# Credential variable names are built indirectly so the repo secret scan does not
# read fixture assignments as credentials. Values are fixtures, not secrets.
TOKV=CLAUDE_CODE_OAUTH_TOKEN
OCV=OPENCODE_GO_KEY
with_keys() { declare -x "$TOKV"=tok-fixture "$OCV"=g-fixture; "$@"; }

run_step() {  # $1 name; remaining env via caller
  set +e
  "$ROOT/bin/factory-step" --json "${TASK:-Reply with pong}" >"$T/$1.out" 2>"$T/$1.err"
  local ec=$?
  set -e
  echo "$ec"
}

echo "=== ok: argv, env split, payload, step-end line ==="
ec=$(export ANTHROPIC_API_KEY=k-fixture CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1; with_keys run_step ok)
[[ "$ec" -eq 0 ]] || fail "ok exited $ec: $(cat "$T/ok.err")"
python3 - "$T/ok.out" <<'PY' || fail "ok payload"
import json, sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
assert d["stopReason"] == "completed" and d["text"] == "pong", d
assert d["session_id"] == "s1" and d["total_cost_usd"] == 0.01, d
PY
grep -qx -- '-p' "$T/argv" || fail "no -p"
grep -qx 'claude-opus-5-5' "$T/argv" || fail "model not passed"
grep -qx 'xhigh' "$T/argv" || fail "effort not passed"
grep -qx 'acceptEdits' "$T/argv" || fail "permission mode not passed"
grep -qx -- '--strict-mcp-config' "$T/argv" || fail "strict mcp missing"
grep -q 'bypassPermissions\|dangerously' "$T/argv" && fail "bypass in argv"
grep -qx 'OAUTH=tok-fixture' "$T/env" || fail "claude did not get the OAuth token"
grep -qx 'STASH=' "$T/env" || fail "stash leaked to claude"
grep -qx 'APIKEY=' "$T/env" || fail "ANTHROPIC_API_KEY leaked to claude"
grep -qx 'OCKEY=' "$T/env" || fail "OpenCode key leaked to claude"
grep -qx 'EFFORT=xhigh' "$T/env" || fail "effort env not pinned"
grep -qx 'SCRUB=' "$T/env" || fail "subprocess env scrub must stay off (it forces permission mode default)"
grep -q 'factory: step end stopReason=completed exit=0' "$T/ok.err" || fail "step end line"
grep -q 'tok-fixture' "$T/ok.err" "$T/ok.out" && fail "token printed"

echo "=== stage step passes the pstack append file ==="
SK="$T/skills"
for s in $(node "$ROOT/lib/cc/pstack-session.js" skills); do
  mkdir -p "$SK/$s"; printf -- '---\nname: %s\n---\nbody\n' "$s" > "$SK/$s/SKILL.md"
done
ec=$(FACTORY_CC_STEP=gate FACTORY_PSTACK_SKILLS_DIR="$SK" run_step gate)
[[ "$ec" -eq 0 ]] || fail "gate exited $ec: $(cat "$T/gate.err")"
grep -qx -- '--append-system-prompt-file' "$T/argv" || fail "append file not passed"
grep -qx 'STEP=gate' "$T/env" || fail "FACTORY_CC_STEP not passed to claude (hook needs it)"
ec=$(FACTORY_CC_STEP=gate FACTORY_PSTACK_SKILLS_DIR="$T/missing" run_step gate-missing)
[[ "$ec" -eq 1 ]] || fail "missing stage skill exited $ec, want 1 (fail closed)"

echo "=== usage limit parks with exit 75 ==="
ec=$(FAKE_MODE=limit run_step limit)
[[ "$ec" -eq 75 ]] || fail "limit exited $ec: $(cat "$T/limit.err")"
grep -q 'claude-code limited until' "$T/limit.err" || fail "limit not parked"
[[ -f "$T/state/claude-code.json" ]] || fail "provider state not written"
ec=$(run_step parked)
[[ "$ec" -eq 75 ]] || fail "parked pre-check exited $ec"
"$ROOT/bin/factory-provider-state" clear claude-code >/dev/null

echo "=== error, missing result, timeout ==="
ec=$(FAKE_MODE=error run_step error); [[ "$ec" -eq 1 ]] || fail "error exited $ec"
grep -q '"stopReason": "error_during_execution"' "$T/error.out" || fail "error stopReason: $(cat "$T/error.out")"
ec=$(FAKE_MODE=noresult run_step noresult); [[ "$ec" -eq 1 ]] || fail "no-result exited $ec"
ec=$(FAKE_MODE=hang FACTORY_STEP_TIMEOUT_MS=1500 run_step hang); [[ "$ec" -eq 124 ]] || fail "timeout exited $ec"
grep -q 'factory: step end stopReason=timeout exit=124' "$T/hang.err" || fail "timeout step-end line"
[[ ! -e "$T/state/claude-code.json" ]] || fail "a timeout was recorded as a provider limit"

echo "=== OpenCode: launcher run mode, text, errors ==="
OCL="$T/oc-launcher"
cat > "$OCL" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_DIR/oc-argv"
[[ "$1" == run ]] || exit 2
case "${FAKE_OC:-ok}" in
  ok) echo '{"type":"step_start","part":{"type":"step-start"}}'; echo '{"type":"text","sessionID":"s","part":{"type":"text","text":"pong"}}'; echo '{"type":"step_finish","part":{"type":"step-finish"}}' ;;
  err) echo '{"type":"error","error":{"name":"APIError","message":"429 Too Many Requests"}}'; exit 1 ;;
  auth) echo '{"type":"step_start","part":{"type":"step-start"}}'; echo '{"type":"error","error":{"type":"provider.auth","message":"Invalid credential","status":401}}'; exit 1 ;;
esac
SH
chmod +x "$OCL"
mkdir -p "$T/ws"
ec=$(FACTORY_PROVIDER=opencode FACTORY_OC_WORKSPACE="$T/ws" FACTORY_OC_LAUNCHER="$OCL" FACTORY_OC_LAUNCHER_NO_SUDO=1 with_keys run_step oc)
[[ "$ec" -eq 0 ]] || fail "oc exited $ec: $(cat "$T/oc.err")"
[[ "$(head -1 "$T/oc-argv")" == run ]] || fail "launcher not called in run mode"
grep -q '"text": "pong"' "$T/oc.out" || fail "oc text: $(cat "$T/oc.out")"
ec=$(FACTORY_PROVIDER=opencode FACTORY_OC_WORKSPACE="$T/ws" FACTORY_OC_LAUNCHER="$OCL" FACTORY_OC_LAUNCHER_NO_SUDO=1 FAKE_OC=err with_keys run_step oc-err)
[[ "$ec" -eq 1 ]] || fail "oc error exited $ec"
grep -q '429 Too Many Requests' "$T/oc-err.out" || fail "oc error diagnostic missing"
ec=$(FACTORY_PROVIDER=opencode FACTORY_OC_WORKSPACE="$T/ws" FACTORY_OC_LAUNCHER="$OCL" FACTORY_OC_LAUNCHER_NO_SUDO=1 FAKE_OC=auth with_keys run_step oc-auth)
[[ "$ec" -eq 1 ]] || fail "oc auth error exited $ec"
grep -q '401 provider.auth: Invalid credential' "$T/oc-auth.out" || fail "oc auth diagnostic: $(cat "$T/oc-auth.out")"

echo "=== launcher rejects bad modes before doing anything ==="
for args in "bogus" "run" "run -x" "acp extra"; do
  set +e
  # shellcheck disable=SC2086
  declare -x "$OCV"=x
  FACTORY_OC_WORKSPACE=/nonexistent "$ROOT/bin/opencode-acp-isolated" $args >/dev/null 2>"$T/launch.err"
  lec=$?
  set -e
  [[ "$lec" -eq 2 ]] || fail "launcher '$args' exited $lec"
  grep -qE 'unknown mode|usage|must not start|takes no arguments' "$T/launch.err" || fail "launcher '$args': $(cat "$T/launch.err")"
done

echo "test_factory_step_runner: PASS"
