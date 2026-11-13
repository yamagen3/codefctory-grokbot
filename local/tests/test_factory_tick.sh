#!/usr/bin/env bash
# factory-tick: one cron-safe entry point for resume + inbox, with a lock and
# a status record. Offline: both hooks are stubs and all state is temporary.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d /tmp/factory-tick-XXXXXX)"
LOCK_PID=""
cleanup() {
  if [[ -n "$LOCK_PID" ]]; then
    kill "$LOCK_PID" 2>/dev/null || true
    wait "$LOCK_PID" 2>/dev/null || true
  fi
  rm -rf "$T"
}
trap cleanup EXIT
fail() { echo "test_factory_tick: FAIL $*" >&2; exit 1; }

unset FACTORY_TICK_PROVIDER_WAIT FACTORY_PROVIDER_WAIT FACTORY_TICK_RESUME_CMD \
  FACTORY_TICK_INBOX_CMD FACTORY_STATUS_DIR FACTORY_LOG_DIR || true
export FACTORY_ROOT="$ROOT"
export FACTORY_STATUS_DIR="$T/status"
mkdir -p "$FACTORY_STATUS_DIR"

RESUME_STUB="$T/resume-stub"
INBOX_STUB="$T/inbox-stub"
RESUME_CALLS="$T/resume.calls"
INBOX_CALLS="$T/inbox.calls"
RESUME_WAIT="$T/resume.wait"
TICK_OUT="$T/tick.out"
TICK_ERR="$T/tick.err"
TICK_RC=0

cat > "$RESUME_STUB" <<'SH'
#!/usr/bin/env bash
set -u
printf 'called\n' >> "${STUB_RESUME_CALL_FILE:?}"
printf '%s\n' "${FACTORY_PROVIDER_WAIT-}" > "${STUB_RESUME_WAIT_FILE:?}"
if [[ -n "${STUB_RESUME_OUT:-}" ]]; then
  printf '%s\n' "$STUB_RESUME_OUT"
fi
exit "${STUB_RESUME_RC:-0}"
SH

cat > "$INBOX_STUB" <<'SH'
#!/usr/bin/env bash
set -u
printf 'called\n' >> "${STUB_INBOX_CALL_FILE:?}"
printf '%s\n' "${STUB_INBOX_OUT:-0}"
exit "${STUB_INBOX_RC:-0}"
SH
chmod +x "$RESUME_STUB" "$INBOX_STUB"

run_tick() {
  local resume_out="$1" resume_rc="$2" inbox_out="$3" inbox_rc="$4"
  set +e
  env \
    FACTORY_ROOT="$ROOT" \
    FACTORY_STATUS_DIR="$FACTORY_STATUS_DIR" \
    FACTORY_LOG_DIR="$T/logs" \
    FACTORY_TICK_RESUME_CMD="$RESUME_STUB" \
    FACTORY_TICK_INBOX_CMD="$INBOX_STUB" \
    STUB_RESUME_OUT="$resume_out" \
    STUB_RESUME_RC="$resume_rc" \
    STUB_INBOX_OUT="$inbox_out" \
    STUB_INBOX_RC="$inbox_rc" \
    STUB_RESUME_CALL_FILE="$RESUME_CALLS" \
    STUB_INBOX_CALL_FILE="$INBOX_CALLS" \
    STUB_RESUME_WAIT_FILE="$RESUME_WAIT" \
    "$ROOT/bin/factory-tick" >"$TICK_OUT" 2>"$TICK_ERR"
  TICK_RC=$?
  set -e
}

clear_calls() { rm -f "$RESUME_CALLS" "$INBOX_CALLS"; }

assert_record() {
  local label="$1" want_resume_rc="$2" want_attention="$3" want_limited="$4"
  python3 - "$FACTORY_STATUS_DIR/tick.json" "$label" "$want_resume_rc" \
    "$want_attention" "$want_limited" <<'PY'
import json
import sys

path, label, resume_rc, attention, limited = sys.argv[1:]
with open(path, encoding="utf-8") as fh:
    doc = json.load(fh)
want_keys = {"time", "resume_rc", "resumed", "attention", "provider_limited"}
assert set(doc) == want_keys, (label, doc)
assert isinstance(doc["time"], str) and doc["time"], (label, doc)
assert isinstance(doc["resumed"], list), (label, doc)
assert isinstance(doc["resume_rc"], int) and not isinstance(doc["resume_rc"], bool), (label, doc)
assert doc["resume_rc"] == int(resume_rc), (label, doc)
assert isinstance(doc["attention"], int) and not isinstance(doc["attention"], bool), (label, doc)
assert doc["attention"] == int(attention), (label, doc)
assert doc["provider_limited"] is (limited == "1"), (label, doc)
PY
}

echo "=== (a) resumed run, quiet inbox: exit 0 and tick.json lists x ==="
clear_calls
run_tick 'resumed x exit=0' 0 0 0
[[ "$TICK_RC" -eq 0 ]] || fail "(a) exit $TICK_RC, want 0: $(cat "$TICK_ERR")"
[[ "$(cat "$TICK_OUT")" == "factory-tick: resumed=1 attention=0 provider=ok" ]] \
  || fail "(a) status line: $(cat "$TICK_OUT")"
assert_record a 0 0 0
python3 - "$FACTORY_STATUS_DIR/tick.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    doc = json.load(fh)
assert doc["resumed"] == ["resumed x exit=0"], doc
PY

echo "=== (b) inbox attention: exit 10 ==="
clear_calls
run_tick '' 0 2 10
[[ "$TICK_RC" -eq 10 ]] || fail "(b) exit $TICK_RC, want 10: $(cat "$TICK_ERR")"
[[ "$(cat "$TICK_OUT")" == "factory-tick: resumed=0 attention=2 provider=ok" ]] \
  || fail "(b) status line: $(cat "$TICK_OUT")"
assert_record b 0 2 0

echo "=== (c) resume still limited: exit 75 and provider_limited ==="
clear_calls
run_tick 'limited 9999999999 2099-01-01T00:00:00+00:00' 75 0 0
[[ "$TICK_RC" -eq 75 ]] || fail "(c) exit $TICK_RC, want 75: $(cat "$TICK_ERR")"
[[ "$(cat "$TICK_OUT")" == "factory-tick: resumed=0 attention=0 provider=limited" ]] \
  || fail "(c) status line: $(cat "$TICK_OUT")"
assert_record c 75 0 1

echo "=== (d) lock held: exit 0 and no hook runs ==="
clear_calls
rm -f "$T/lock-held" "$T/lock-release"
(
  exec 8>"$FACTORY_STATUS_DIR/tick.lock"
  flock -n 8 || exit 1
  : > "$T/lock-held"
  while [[ ! -e "$T/lock-release" ]]; do sleep 0.05; done
) &
LOCK_PID=$!
for _ in {1..100}; do
  [[ -e "$T/lock-held" ]] && break
  sleep 0.05
done
[[ -e "$T/lock-held" ]] || fail "(d) background flock did not take the lock"
run_tick 'resumed must-not-run' 0 0 0
[[ "$TICK_RC" -eq 0 ]] || fail "(d) exit $TICK_RC, want 0: $(cat "$TICK_ERR")"
[[ "$(cat "$TICK_OUT")" == "factory-tick: already running" ]] \
  || fail "(d) output: $(cat "$TICK_OUT")"
[[ ! -e "$RESUME_CALLS" ]] || fail "(d) resume stub ran while the lock was held"
[[ ! -e "$INBOX_CALLS" ]] || fail "(d) inbox stub ran while the lock was held"
: > "$T/lock-release"
wait "$LOCK_PID" || true
LOCK_PID=""

echo "=== (e) resume hook sees FACTORY_PROVIDER_WAIT=0 ==="
clear_calls
rm -f "$RESUME_WAIT"
run_tick 'resumed e exit=0' 0 0 0
[[ "$TICK_RC" -eq 0 ]] || fail "(e) exit $TICK_RC, want 0: $(cat "$TICK_ERR")"
[[ "$(cat "$RESUME_WAIT")" == "0" ]] \
  || fail "(e) resume saw FACTORY_PROVIDER_WAIT=$(cat "$RESUME_WAIT"), want 0"

echo "=== (f) failing resume is logged, inbox still runs: exit 0 ==="
clear_calls
run_tick 'resume exploded' 1 0 0
[[ "$TICK_RC" -eq 0 ]] || fail "(f) exit $TICK_RC, want 0: $(cat "$TICK_ERR")"
[[ -e "$INBOX_CALLS" ]] || fail "(f) inbox stub did not run after a failing resume"
grep -qi 'resume.*failed' "$TICK_ERR" \
  || fail "(f) resume failure was not logged: $(cat "$TICK_ERR")"
assert_record f 1 0 0

echo "=== (g) tick keeps the full resume log and counts only structured lines ==="
clear_calls
rm -rf "$T/logs"
run_tick $'noise\nresumed x exit=0\nresumed by hand' 0 0 0
[[ "$TICK_RC" -eq 0 ]] || fail "(g) exit $TICK_RC, want 0: $(cat "$TICK_ERR")"
[[ "$(cat "$TICK_OUT")" == "factory-tick: resumed=1 attention=0 provider=ok" ]] \
  || fail "(g) status line: $(cat "$TICK_OUT")"
python3 - "$FACTORY_STATUS_DIR/tick.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    doc = json.load(fh)
assert doc["resumed"] == ["resumed x exit=0"], doc
PY
LOG="$T/logs/tick-resume.log"
[[ -f "$LOG" ]] || fail "(g) missing tick-resume.log"
[[ "$(grep -c '^=== tick ' "$LOG")" -eq 1 ]] || fail "(g) missing tick heading"
grep -Fqx 'noise' "$LOG" || fail "(g) tick-resume.log lost noise"
grep -Fqx 'resumed x exit=0' "$LOG" || fail "(g) tick-resume.log lost resumed x"
grep -Fqx 'resumed by hand' "$LOG" || fail "(g) tick-resume.log lost resumed by hand"

echo "test_factory_tick: PASS"
