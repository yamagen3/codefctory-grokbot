#!/usr/bin/env bash
# Offline: Claude Code usage-limit classification, provider state, factory-step parking,
# and stall-retry resume after the reset. No model or network calls.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d /tmp/factory-provider-limit-XXXXXX)"
trap 'rm -rf "$T"' EXIT

export FACTORY_PROVIDER_STATE_DIR="$T/state"
export FACTORY_NOTIFY_DIR="$T/notify"
export FACTORY_PROVIDER_SLEEP_SCALE=0
export FACTORY_USAGE_DIR="$T/usage"
unset FACTORY_AGMSG_TEAM FACTORY_PROVIDER_IGNORE_LIMIT FACTORY_PROVIDER_WAIT

PS="$ROOT/bin/factory-provider-state"
fail() { echo "test_provider_limit: FAIL $*" >&2; exit 1; }

echo "=== classify usage limits ==="
cat > "$T/usage-limit.jsonl" <<'JSON'
{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":429,"api_error_origin":"first_party","api_error":"usage_limit_reached","result":"You've hit your 5-hour limit · resets 11:20am (Asia/Tokyo)"}
JSON
out=$("$PS" classify "$T/usage-limit.jsonl")
read -r status epoch reason <<<"$out"
[[ "$status" == "limited" ]] || fail "sample line not limited: $out"
[[ "$reason" == "usage_limit_reached" ]] || fail "sample reason: $reason"
[[ "$epoch" =~ ^[0-9]+$ ]] || fail "sample epoch not numeric: $epoch"
now=$(date +%s)
[[ "$epoch" -gt "$now" && "$epoch" -le $((now + 86400)) ]] || fail "sample reset not in the next 24h: $epoch now=$now"

printf '%s\n' '{"is_error":false,"subtype":"success"}' > "$T/usage-ok.jsonl"
[[ "$("$PS" classify "$T/usage-ok.jsonl")" == "ok" ]] || fail "success result not ok"
[[ "$("$PS" classify "$T/no-such-file.jsonl")" == "ok" ]] || fail "missing file not ok"
: > "$T/usage-empty.jsonl"
[[ "$("$PS" classify "$T/usage-empty.jsonl")" == "ok" ]] || fail "empty file not ok"
printf 'not json\n' > "$T/usage-invalid.jsonl"
[[ "$("$PS" classify "$T/usage-invalid.jsonl")" == "ok" ]] || fail "invalid file not ok"

printf '%s\n' '{"api_error":"usage_limit_reached","result":"You have hit your limit · resets 6am (Asia/Tokyo)"}' > "$T/usage-6am.jsonl"
out=$("$PS" classify "$T/usage-6am.jsonl")
read -r status epoch rest <<<"$out"
[[ "$status" == "limited" ]] || fail "6am line not limited: $out"
hour=$(python3 - "$epoch" <<'PY'
import datetime
import sys
from zoneinfo import ZoneInfo

print(datetime.datetime.fromtimestamp(int(sys.argv[1]), ZoneInfo("Asia/Tokyo")).hour)
PY
)
[[ "$hour" == "6" ]] || fail "6am reset landed at hour $hour in Asia/Tokyo"

echo "=== provider state mark/check/clear ==="
now=$(date +%s)
"$PS" mark claude-code $((now + 3600)) usage_limit_reached
set +e
out=$("$PS" check claude-code)
ec=$?
set -e
[[ "$ec" -eq 75 ]] || fail "limited check exited $ec, want 75"
[[ "$out" == limited\ * ]] || fail "limited check output: $out"
[[ -f "$FACTORY_PROVIDER_STATE_DIR/claude-code.json" ]] || fail "mark did not write the state file"

"$PS" mark claude-code $((now - 5)) expired
set +e
out=$("$PS" check claude-code)
ec=$?
set -e
[[ "$ec" -eq 0 && "$out" == "ok" ]] || fail "expired check ec=$ec out=$out"
[[ ! -e "$FACTORY_PROVIDER_STATE_DIR/claude-code.json" ]] || fail "expired state file was not deleted"

"$PS" mark claude-code $((now + 3600)) clear-me
"$PS" clear claude-code
[[ ! -e "$FACTORY_PROVIDER_STATE_DIR/claude-code.json" ]] || fail "clear did not remove the state file"
[[ "$("$PS" check claude-code)" == "ok" ]] || fail "check after clear not ok"

echo "=== factory-step pre-check parks without running dsh ==="
cat > "$T/dsh-marker" <<SH
#!/usr/bin/env bash
echo called > "$T/dsh-called"
exit 0
SH
chmod +x "$T/dsh-marker"
"$PS" mark claude-code $((now + 3600)) usage_limit_reached
rm -f "$T/dsh-called"
set +e
FACTORY_PROVIDER=claude-code FACTORY_USAGE_DISABLE=1 FACTORY_DSH_BIN="$T/dsh-marker" \
  "$ROOT/bin/factory-step" --json x >"$T/step-pre.out" 2>"$T/step-pre.err"
ec=$?
set -e
[[ "$ec" -eq 75 ]] || fail "pre-check factory-step exited $ec, want 75 (stderr: $(cat "$T/step-pre.err"))"
[[ ! -e "$T/dsh-called" ]] || fail "pre-check still ran dsh"
grep -q 'factory-step: claude-code limited until .*; parked (exit 75)' "$T/step-pre.err" ||
  fail "pre-check parked line missing from stderr"
shopt -s nullglob
notes=("$FACTORY_NOTIFY_DIR"/*-provider-limited.txt)
shopt -u nullglob
[[ "${#notes[@]}" -ge 1 ]] || fail "pre-check wrote no *-provider-limited.txt notification"
grep -q 'claude-code limited until ' "${notes[0]}" || fail "pre-check notification message missing"

echo "=== factory-step post-classify marks the limit ==="
"$PS" clear claude-code
cat > "$T/dsh-limit" <<'SH'
#!/usr/bin/env bash
cat <<'JSON' >> "${FACTORY_CC_USAGE_FILE:?}"
{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":429,"api_error_origin":"first_party","api_error":"usage_limit_reached","result":"You've hit your 5-hour limit · resets 11:20am (Asia/Tokyo)"}
JSON
exit 1
SH
chmod +x "$T/dsh-limit"
set +e
FACTORY_PROVIDER=claude-code FACTORY_DSH_BIN="$T/dsh-limit" \
  "$ROOT/bin/factory-step" --json x >"$T/step-post.out" 2>"$T/step-post.err"
ec=$?
set -e
[[ "$ec" -eq 75 ]] || fail "post-classify factory-step exited $ec, want 75 (stderr: $(cat "$T/step-post.err"))"
[[ -f "$FACTORY_PROVIDER_STATE_DIR/claude-code.json" ]] || fail "post-classify did not write the state file"
grep -q 'factory-step: claude-code limited until .*; parked (exit 75)' "$T/step-post.err" ||
  fail "post-classify parked line missing from stderr"
if ! python3 - "$FACTORY_PROVIDER_STATE_DIR/claude-code.json" <<'PY'
import json
import sys
import time

with open(sys.argv[1], encoding="utf-8") as fh:
    doc = json.load(fh)
assert doc["provider"] == "claude-code", doc
assert doc["state"] == "limited", doc
assert int(doc["reset_epoch"]) > int(time.time()), doc
assert doc["reason"] == "usage_limit_reached", doc
assert doc["marked_at"], doc
PY
then
  fail "post-classify state file contents are wrong"
fi

echo "=== stall-retry waits and reruns after exit 75 ==="
cat > "$T/flaky75" <<'SH'
#!/usr/bin/env bash
n=0
[ -f "$COUNT_FILE" ] && n=$(cat "$COUNT_FILE")
n=$((n + 1))
printf '%s\n' "$n" > "$COUNT_FILE"
if [[ "$n" -eq 1 ]]; then exit 75; fi
exit 0
SH
chmod +x "$T/flaky75"

now=$(date +%s)
"$PS" mark claude-code $((now + 2)) wait-test
set +e
COUNT_FILE="$T/count-wait" FACTORY_PROVIDER_WAIT=1 \
  "$ROOT/bin/factory-stall-retry" step -- "$T/flaky75" >"$T/stall-wait.out" 2>"$T/stall-wait.err"
ec=$?
set -e
[[ "$ec" -eq 0 ]] || fail "stall-retry with wait exited $ec, want 0 (stderr: $(cat "$T/stall-wait.err"))"
[[ "$(cat "$T/count-wait")" -eq 2 ]] || fail "stall-retry with wait ran the command $(cat "$T/count-wait") times, want 2"

now=$(date +%s)
"$PS" mark claude-code $((now + 3600)) wait-disabled
set +e
COUNT_FILE="$T/count-no-wait" FACTORY_PROVIDER_WAIT=0 \
  "$ROOT/bin/factory-stall-retry" step -- "$T/flaky75" >"$T/stall-no-wait.out" 2>"$T/stall-no-wait.err"
ec=$?
set -e
[[ "$ec" -eq 75 ]] || fail "stall-retry with FACTORY_PROVIDER_WAIT=0 exited $ec, want 75"
[[ "$(cat "$T/count-no-wait")" -eq 1 ]] || fail "FACTORY_PROVIDER_WAIT=0 still retried the command"

"$PS" clear claude-code
set +e
COUNT_FILE="$T/count-unlimited" FACTORY_PROVIDER_WAIT=1 \
  "$ROOT/bin/factory-stall-retry" step -- "$T/flaky75" >"$T/stall-unlimited.out" 2>"$T/stall-unlimited.err"
ec=$?
set -e
[[ "$ec" -eq 75 ]] || fail "exit 75 without a provider limit exited $ec, want 75"
[[ "$(cat "$T/count-unlimited")" -eq 1 ]] || fail "exit 75 without a provider limit was retried"

echo "test_provider_limit: PASS"
