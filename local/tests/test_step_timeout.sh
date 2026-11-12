#!/usr/bin/env bash
# Offline: step timeout budget, exit 124 propagation, and stall-retry export.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d /tmp/factory-step-timeout-XXXXXX)"
trap 'rm -rf "$T"' EXIT

fail() { echo "test_step_timeout: FAIL $*" >&2; exit 1; }

NODE="${NODE:-$(command -v node || true)}"
if [[ -z "$NODE" && -x /usr/local/bin/node ]]; then NODE=/usr/local/bin/node; fi
[[ -n "$NODE" && -x "$NODE" ]] || fail "node not found"

unset FACTORY_AGMSG_TEAM

echo "=== helper timeout resolution ==="
helper_js="$(cat <<'JS'
import {
  DEFAULT_TIMEOUT_MS,
  TIMEOUT_EXIT_CODE,
  resolveTimeoutMs,
  exitCodeFor,
} from './plugin/step-timeout.js'

if (DEFAULT_TIMEOUT_MS !== 1800000) throw new Error(`DEFAULT_TIMEOUT_MS=${DEFAULT_TIMEOUT_MS}`)
if (TIMEOUT_EXIT_CODE !== 124) throw new Error(`TIMEOUT_EXIT_CODE=${TIMEOUT_EXIT_CODE}`)

const cases = [
  ['configured', resolveTimeoutMs(1800000, {}), 1800000],
  ['undefined config', resolveTimeoutMs(undefined, {}), 1800000],
  ['stall 3600', resolveTimeoutMs(1800000, { FACTORY_STALL_TIMEOUT_SEC: '3600' }), 3240000],
  ['stall 5', resolveTimeoutMs(1800000, { FACTORY_STALL_TIMEOUT_SEC: '5' }), 2500],
  ['step beats stall', resolveTimeoutMs(1800000, { FACTORY_STEP_TIMEOUT_MS: '1234', FACTORY_STALL_TIMEOUT_SEC: '3600' }), 1234],
  ['step abc', resolveTimeoutMs(1800000, { FACTORY_STEP_TIMEOUT_MS: 'abc' }), 1800000],
  ['step 0', resolveTimeoutMs(1800000, { FACTORY_STEP_TIMEOUT_MS: '0' }), 1800000],
  ['step -5', resolveTimeoutMs(1800000, { FACTORY_STEP_TIMEOUT_MS: '-5' }), 1800000],
  ['stall abc', resolveTimeoutMs(1800000, { FACTORY_STALL_TIMEOUT_SEC: 'abc' }), 1800000],
  ['stall 0', resolveTimeoutMs(1800000, { FACTORY_STALL_TIMEOUT_SEC: '0' }), 1800000],
  ['stall -5', resolveTimeoutMs(1800000, { FACTORY_STALL_TIMEOUT_SEC: '-5' }), 1800000],
]
for (const [name, got, want] of cases) {
  if (got !== want) throw new Error(`${name}: got ${got}, want ${want}`)
}

const exits = [
  ['completed despite timeout', exitCodeFor('completed', true), 0],
  ['cancelled timed out', exitCodeFor('cancelled', true), 124],
  ['error not timed out', exitCodeFor('error', false), 1],
]
for (const [name, got, want] of exits) {
  if (got !== want) throw new Error(`${name}: got ${got}, want ${want}`)
}

console.log(`helper ok (${cases.length + exits.length} cases)`)
JS
)"
(cd "$ROOT" && "$NODE" --input-type=module -e "$helper_js") || fail "helper assertions failed"

grep -Fq "step-timeout.js" "$ROOT/plugin/index.js" || fail "plugin/index.js does not import step-timeout.js"
grep -Fq "inject = ['agents', 'subagents']" "$ROOT/plugin/index.js" || fail "plugin/index.js lost its inject list"

echo "=== factory-step propagates timeout exit 124 ==="
FAKE_DSH="$T/fake-dsh"
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
  FACTORY_DSH_BIN="$FAKE_DSH" \
  FACTORY_USAGE_DISABLE=1 \
  FACTORY_PROVIDER=claude-code \
  FAKE_EC="$fake_ec" \
    "$ROOT/bin/factory-step" --json x >"$T/step-${fake_ec}.out" 2>"$T/step-${fake_ec}.err"
  got=$?
  set -e
  [[ "$got" -eq 124 ]] || fail "fake dsh exit ${fake_ec}: factory-step exited ${got}, want 124 (stderr: $(cat "$T/step-${fake_ec}.err"))"
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
