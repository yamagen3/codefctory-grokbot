#!/usr/bin/env bash
# Offline: step timeout budget, exit 124 propagation, and stall-retry export.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d /tmp/factory-step-timeout-XXXXXX)"
trap 'rm -rf "$T"' EXIT

fail() { echo "test_step_timeout: FAIL $*" >&2; exit 1; }

unset FACTORY_AGMSG_TEAM

echo "=== helper timeout resolution ==="
(cd "$ROOT" && python3 - <<'PY') || fail "helper assertions failed"
import sys
sys.path.insert(0, "lib")
from factory_step import DEFAULT_TIMEOUT_MS, TIMEOUT_EXIT_CODE, resolve_timeout_ms, exit_code_for

assert DEFAULT_TIMEOUT_MS == 1800000, DEFAULT_TIMEOUT_MS
assert TIMEOUT_EXIT_CODE == 124, TIMEOUT_EXIT_CODE
cases = [
    ("configured", resolve_timeout_ms(1800000, {}), 1800000),
    ("undefined config", resolve_timeout_ms(None, {}), 1800000),
    ("stall 3600", resolve_timeout_ms(1800000, {"FACTORY_STALL_TIMEOUT_SEC": "3600"}), 3240000),
    ("stall 5", resolve_timeout_ms(1800000, {"FACTORY_STALL_TIMEOUT_SEC": "5"}), 2500),
    ("step beats stall", resolve_timeout_ms(1800000, {"FACTORY_STEP_TIMEOUT_MS": "1234", "FACTORY_STALL_TIMEOUT_SEC": "3600"}), 1234),
    ("step abc", resolve_timeout_ms(1800000, {"FACTORY_STEP_TIMEOUT_MS": "abc"}), 1800000),
    ("step 0", resolve_timeout_ms(1800000, {"FACTORY_STEP_TIMEOUT_MS": "0"}), 1800000),
    ("step -5", resolve_timeout_ms(1800000, {"FACTORY_STEP_TIMEOUT_MS": "-5"}), 1800000),
    ("stall abc", resolve_timeout_ms(1800000, {"FACTORY_STALL_TIMEOUT_SEC": "abc"}), 1800000),
    ("stall 0", resolve_timeout_ms(1800000, {"FACTORY_STALL_TIMEOUT_SEC": "0"}), 1800000),
    ("stall -5", resolve_timeout_ms(1800000, {"FACTORY_STALL_TIMEOUT_SEC": "-5"}), 1800000),
]
for name, got, want in cases:
    assert got == want, f"{name}: got {got}, want {want}"
exits = [
    ("completed despite timeout", exit_code_for(True, True), 0),
    ("not completed, timed out", exit_code_for(False, True), 124),
    ("error not timed out", exit_code_for(False, False), 1),
]
for name, got, want in exits:
    assert got == want, f"{name}: got {got}, want {want}"
print(f"helper ok ({len(cases) + len(exits)} cases)")
PY

echo "=== factory-step propagates timeout exit 124 ==="
FAKE_DSH="$T/fake-runner"
cat > "$FAKE_DSH" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"stopReason":"timeout","output":[]}'
printf '%s\n' 'factory: step end stopReason=timeout exit=124' >&2
exit "${FAKE_EC:-0}"
SH
chmod +x "$FAKE_DSH"

for fake_ec in 0 1 124; do
  set +e
  FACTORY_ROOT="$ROOT" \
  FACTORY_STEP_RUNNER="$FAKE_DSH" \
  FACTORY_USAGE_DISABLE=1 \
  FACTORY_PROVIDER=claude-code \
  FAKE_EC="$fake_ec" \
    "$ROOT/bin/factory-step" --json x >"$T/step-${fake_ec}.out" 2>"$T/step-${fake_ec}.err"
  got=$?
  set -e
  [[ "$got" -eq 124 ]] || fail "fake runner exit ${fake_ec}: factory-step exited ${got}, want 124 (stderr: $(cat "$T/step-${fake_ec}.err"))"
done

echo "=== stall retry exports timeout and retries once ==="
STALL_CMD="$T/stall-cmd"
cat > "$STALL_CMD" <<'SH'
#!/usr/bin/env bash
printf 'attempt\n' >> "$COUNTER_FILE"
printf '%s\n' "${FACTORY_STALL_TIMEOUT_SEC:-}" >> "$RECORD_FILE"
exit 124
SH
chmod +x "$STALL_CMD"

run_stall() {
  local counter="$1" record="$2" notify="$3"
  mkdir -p "$notify"
  set +e
  env -u FACTORY_AGMSG_TEAM ${FACTORY_STALL_TIMEOUT_SEC:+FACTORY_STALL_TIMEOUT_SEC="$FACTORY_STALL_TIMEOUT_SEC"} \
    COUNTER_FILE="$counter" RECORD_FILE="$record" FACTORY_NOTIFY_DIR="$notify" \
    "$ROOT/bin/factory-stall-retry" step -- "$STALL_CMD" >"$T/stall.out" 2>"$T/stall.err"
  local ec=$?
  set -e
  [[ "$ec" -eq 124 ]] || fail "factory-stall-retry exited ${ec}, want 124 (stderr: $(cat "$T/stall.err"))"
}

COUNTER1="$T/counter-set"
RECORD1="$T/record-set"
NOTIFY1="$T/notify-set"
FACTORY_STALL_TIMEOUT_SEC=7 run_stall "$COUNTER1" "$RECORD1" "$NOTIFY1"
[[ "$(wc -l < "$COUNTER1")" -eq 2 ]] || fail "expected two stall attempts, got $(wc -l < "$COUNTER1")"
grep -qx '7' "$RECORD1" || fail "child did not see FACTORY_STALL_TIMEOUT_SEC=7"
shopt -s nullglob
stall_notes=("$NOTIFY1"/*-stall.txt)
shopt -u nullglob
[[ "${#stall_notes[@]}" -ge 1 ]] || fail "no *-stall.txt notification written"

COUNTER2="$T/counter-default"
RECORD2="$T/record-default"
NOTIFY2="$T/notify-default"
run_stall "$COUNTER2" "$RECORD2" "$NOTIFY2"
[[ "$(wc -l < "$COUNTER2")" -eq 2 ]] || fail "expected two default stall attempts, got $(wc -l < "$COUNTER2")"
grep -qx '3600' "$RECORD2" || fail "unset FACTORY_STALL_TIMEOUT_SEC did not record 3600"

echo "test_step_timeout: PASS"
