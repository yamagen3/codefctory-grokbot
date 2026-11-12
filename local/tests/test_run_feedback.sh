#!/usr/bin/env bash
# Round feedback: write/prompt helper, then run-local scenarios with stubs.
# Offline: local bare origin, no network, no secrets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d /tmp/factory-run-feedback-XXXXXX)"
trap 'rm -rf "$T"' EXIT
fail() { echo "test_run_feedback: FAIL $*" >&2; exit 1; }

unset FACTORY_AGMSG_TEAM FACTORY_RUNS_DIR FACTORY_NOTIFY_DIR FACTORY_WORK_DIR \
  FACTORY_GROK_HOOK_DIR FACTORY_ORIGIN_REINIT FACTORY_MAX_ROUNDS \
  FACTORY_GROK_MODE FACTORY_GROK_STUB FACTORY_CLAUDE_GATE_STUB || true
export GIT_AUTHOR_NAME=factory GIT_AUTHOR_EMAIL=factory@localhost
export GIT_COMMITTER_NAME=factory GIT_COMMITTER_EMAIL=factory@localhost

FB="$ROOT/bin/factory-feedback"
HELPER_RUNS="$T/helper-runs"
helper() { FACTORY_ROOT="$ROOT" FACTORY_RUNS_DIR="$HELPER_RUNS" "$FB" "$@"; }

echo "=== helper: write then prompt round-trip ==="
printf 'AssertionError: expected 42\n' > "$T/detail.txt"
helper write sample 2 ci "tests failed" "$T/detail.txt"
FB2="$HELPER_RUNS/sample/feedback-r2.md"
[[ -f "$FB2" ]] || fail "write did not create feedback-r2.md"
grep -Fq '# Round 2 failed at ci' "$FB2" || fail "missing round/stage header"
grep -Fq 'summary: tests failed' "$FB2" || fail "missing summary"
grep -Fq 'AssertionError: expected 42' "$FB2" || fail "missing detail"
out="$(helper prompt sample 3)"
[[ "$out" == $'\n\nPrevious round was rejected. Fix exactly this and keep what already passes:'* ]] \
  || fail "prompt did not start with the rejection preamble"
[[ "$out" == *'Round 2 failed at ci'* ]] || fail "prompt did not include the previous feedback"
[[ "$out" == *'AssertionError: expected 42'* ]] || fail "prompt did not include the previous detail"

echo "=== helper: prompt round 1 is empty ==="
helper prompt sample 1 > "$T/prompt-r1-empty.bin"
[[ ! -s "$T/prompt-r1-empty.bin" ]] || fail "prompt round 1 was not empty"

echo "=== helper: 200 lines keep only the last 60 ==="
for i in $(seq -w 1 200); do printf 'line-%s\n' "$i"; done > "$T/long.txt"
helper write sample 4 guard "protected paths changed" "$T/long.txt"
FB4="$HELPER_RUNS/sample/feedback-r4.md"
[[ -f "$FB4" ]] || fail "write did not create feedback-r4.md"
grep -Fq 'line-200' "$FB4" || fail "last detail line was dropped"
if grep -Fq 'line-001' "$FB4"; then fail "first detail line survived"; fi
if grep -Fq 'line-140' "$FB4"; then fail "detail kept more than 60 lines"; fi
detail_lines="$(awk '/^```$/{f=!f; next} f && /^line-/' "$FB4" | wc -l)"
[[ "$detail_lines" -eq 60 ]] || fail "kept $detail_lines detail lines, want 60"

echo "=== helper: redaction ==="
printf 'safe line\nAPI_KEY=abc123\nanother safe line\n' > "$T/secret.txt"
helper write sample 5 ci "tests failed" "$T/secret.txt"
FB5="$HELPER_RUNS/sample/feedback-r5.md"
if grep -Fq 'API_KEY=abc123' "$FB5"; then fail "secret line was not redacted"; fi
grep -Fq '[redacted line]' "$FB5" || fail "missing redacted marker"

echo "=== helper: JSON detail text ==="
printf '%s' '{"text":"GATE: FAIL\nmissing --help"}' > "$T/detail.json"
helper write sample 6 gate-claude "gate/claude rejected the change" "$T/detail.json"
FB6="$HELPER_RUNS/sample/feedback-r6.md"
grep -Fq 'missing --help' "$FB6" || fail "JSON text detail was not used"
grep -Fq 'GATE: FAIL' "$FB6" || fail "JSON text detail lost its first line"

echo "=== helper: control characters are dropped ==="
printf 'keep\tthis\nbad\rline\nesc\033[31mred\n' > "$T/control.txt"
helper write sample 7 ci "tests failed" "$T/control.txt"
FB7="$HELPER_RUNS/sample/feedback-r7.md"
if grep -q $'\r' "$FB7"; then fail "carriage return survived"; fi
if grep -q $'\033' "$FB7"; then fail "escape character survived"; fi
grep -Fq $'keep\tthis' "$FB7" || fail "tab was dropped"

echo "=== helper: invalid id ==="
set +e
helper write ../x 1 ci "tests failed" >"$T/invalid-id.out" 2>&1
invalid_ec=$?
set -e
[[ "$invalid_ec" -ne 0 ]] || fail "id ../x was accepted"

echo "=== part B: fake root ==="
FAKE="$T/root"
mkdir -p "$FAKE/bin" "$FAKE/local/origin"
for f in factory-run-local factory-common.sh factory-feedback factory-notify factory-stall-retry; do
  cp "$ROOT/bin/$f" "$FAKE/bin/$f"
  chmod +x "$FAKE/bin/$f"
done

PREPARED="$FAKE/local/origin/t.git"
git init --bare -q -b main "$PREPARED"
SEED="$T/seed"
git init -q -b main "$SEED"
printf 'base\n' > "$SEED/README.md"
git -C "$SEED" add README.md
git -C "$SEED" commit -q -m base
git -C "$SEED" remote add origin "$PREPARED"
git -C "$SEED" push -q -u origin main
rm -rf "$SEED"

cat > "$FAKE/bin/factory-local-origin" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"; shift || true
case "$cmd" in
  clone)
    name="${1:-}"; dest="${2:-}"
    [[ -n "$name" && -n "$dest" ]] || exit 1
    rm -rf "$dest"
    git clone "$PREPARED_BARE" "$dest" >/dev/null 2>&1
    ;;
  init)
    ;;
  *) echo "factory-local-origin stub: bad command $cmd" >&2; exit 1 ;;
esac
SH

cat > "$FAKE/bin/factory-impl-step" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
repo="${1:?}"; id="${2:-}"; prompt="${3:-}"
n=$(( $(cat "$IMPL_COUNTER" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$IMPL_COUNTER"
printf '%s' "$prompt" > "$PROMPT_DIR/prompt-r${n}.txt"
printf 'impl %s\n' "$n" >> "$repo/IMPL.txt"
git -C "$repo" add IMPL.txt
git -C "$repo" -c user.email=factory@localhost -c user.name=factory commit -q -m "impl $n"
if [[ -n "${IMPL_FAIL_AT:-}" && "$n" -eq "${IMPL_FAIL_AT}" ]]; then
  echo "impl stub failure n=$n" >&2
  exit 1
fi
SH

cat > "$FAKE/bin/factory-guard" <<'SH'
#!/usr/bin/env bash
echo "guard ok"
exit "${GUARD_EC:-0}"
SH

cat > "$FAKE/bin/factory-ci" <<'SH'
#!/usr/bin/env bash
n=$(( $(cat "$CI_COUNTER" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$CI_COUNTER"
if [[ -n "${CI_FAIL_AT:-}" && "$n" -eq "${CI_FAIL_AT}" ]]; then
  echo "AssertionError: expected 42"
  exit 1
fi
echo "ci ok attempt=$n"
exit 0
SH

cat > "$FAKE/bin/factory-gate-claude" <<'SH'
#!/usr/bin/env bash
n=$(( $(cat "$GATE_CLAUDE_COUNTER" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$GATE_CLAUDE_COUNTER"
read -r -a codes <<< "${GATE_CLAUDE_CODES:-0}"
idx=$((n - 1))
if [[ "$idx" -ge "${#codes[@]}" ]]; then idx=$(( ${#codes[@]} - 1 )); fi
ec="${codes[$idx]}"
echo "gate-claude attempt=$n ec=$ec"
if [[ "$ec" -ne 0 ]]; then
  printf '{"text":"GATE: FAIL\\nstub"}\n' > "${FACTORY_GATE_CLAUDE_OUT:-/tmp/factory-gate-claude.json}"
fi
exit "$ec"
SH

cat > "$FAKE/bin/factory-gate-grok" <<'SH'
#!/usr/bin/env bash
n=$(( $(cat "$GROK_COUNTER" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$GROK_COUNTER"
read -r -a codes <<< "${GROK_CODES:-0}"
idx=$((n - 1))
if [[ "$idx" -ge "${#codes[@]}" ]]; then idx=$(( ${#codes[@]} - 1 )); fi
ec="${codes[$idx]}"
echo "gate-grok attempt=$n ec=$ec"
exit "$ec"
SH

cat > "$FAKE/bin/factory-merge" <<'SH'
#!/usr/bin/env bash
echo "merge ok"
exit "${MERGE_EC:-0}"
SH

cat > "$FAKE/bin/factory-status" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "$FAKE/bin/factory-labels" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "$FAKE/bin/factory-usage" <<'SH'
#!/usr/bin/env bash
exit 0
SH

chmod +x "$FAKE/bin"/*

run_factory() {
  local name="$1"; shift
  RUN_WORK="$T/work-$name"
  RUN_RUNS="$T/runs-$name"
  RUN_NOTIFY="$T/notify-$name"
  RUN_PROMPTS="$T/prompts-$name"
  mkdir -p "$RUN_RUNS" "$RUN_NOTIFY" "$RUN_PROMPTS"
  set +e
  env \
    FACTORY_ROOT="$FAKE" \
    FACTORY_TARGET_NAME=t \
    FACTORY_SKIP_CC_SPEC=1 \
    FACTORY_WORK_DIR="$RUN_WORK" \
    FACTORY_RUNS_DIR="$RUN_RUNS" \
    FACTORY_NOTIFY_DIR="$RUN_NOTIFY" \
    FACTORY_GROK_HOOK_DIR="$T/hooks-$name" \
    FACTORY_GATE_CLAUDE_OUT="$T/gate-claude-$name.json" \
    FACTORY_STALL_TIMEOUT_SEC=30 \
    PREPARED_BARE="$PREPARED" \
    IMPL_COUNTER="$T/impl-count-$name" \
    PROMPT_DIR="$RUN_PROMPTS" \
    CI_COUNTER="$T/ci-count-$name" \
    GATE_CLAUDE_COUNTER="$T/gate-claude-count-$name" \
    GROK_COUNTER="$T/grok-count-$name" \
    "$@" \
    "$FAKE/bin/factory-run-local" "$name" >"$T/log-$name" 2>&1
  RUN_RC=$?
  set -e
}

notify_glob() {
  local dir="$1" kind="$2"
  compgen -G "$dir/*-${kind}.txt" || true
}

echo "=== (a) CI fails once, feedback reaches the next IMPL prompt ==="
run_factory a CI_FAIL_AT=1
[[ "$RUN_RC" -eq 0 ]] || fail "case a: exit $RUN_RC: $(cat "$T/log-a")"
[[ "$(cat "$T/impl-count-a")" -eq 2 ]] || fail "case a: impl ran $(cat "$T/impl-count-a") times, want 2"
EXPECTED_PROMPT='Implement per spec/PRODUCT.md; make acceptance tests pass; stdlib only. Do not modify spec/, tests/acceptance/, or .github/.'
[[ "$(cat "$RUN_PROMPTS/prompt-r1.txt")" == "$EXPECTED_PROMPT" ]] \
  || fail "case a: round 1 prompt changed"
grep -Fq 'Round 1 failed at ci' "$RUN_PROMPTS/prompt-r2.txt" \
  || fail "case a: round 2 prompt missing the failed round header"
grep -Fq 'AssertionError: expected 42' "$RUN_PROMPTS/prompt-r2.txt" \
  || fail "case a: round 2 prompt missing the CI detail"
[[ -f "$RUN_RUNS/a/ci-r1.log" ]] || fail "case a: missing ci-r1.log"

echo "=== (b) IMPL failure is an aborted run with stage=impl ==="
run_factory b IMPL_FAIL_AT=1
[[ "$RUN_RC" -eq 1 ]] || fail "case b: exit $RUN_RC, want 1"
aborted="$(notify_glob "$RUN_NOTIFY" run-aborted)"
[[ -n "$aborted" ]] || fail "case b: no run-aborted notification"
grep -Fq 'stage=impl' $aborted || fail "case b: run-aborted lost stage=impl"

echo "=== (c) gate unavailable twice exits 75 without another IMPL round ==="
run_factory c GATE_CLAUDE_CODES="75 75"
[[ "$RUN_RC" -eq 75 ]] || fail "case c: exit $RUN_RC, want 75"
[[ "$(cat "$T/impl-count-c")" -eq 1 ]] || fail "case c: impl ran $(cat "$T/impl-count-c") times, want 1"
[[ "$(cat "$T/gate-claude-count-c")" -eq 2 ]] || fail "case c: gate retry count was not 2"
[[ -n "$(notify_glob "$RUN_NOTIFY" gate-unavailable)" ]] || fail "case c: no gate-unavailable notification"
[[ -z "$(notify_glob "$RUN_NOTIFY" run-aborted)" ]] || fail "case c: unexpected run-aborted notification"

echo "=== (d) gate unavailable then pass exits 0 with one IMPL round ==="
run_factory d GATE_CLAUDE_CODES="75 0"
[[ "$RUN_RC" -eq 0 ]] || fail "case d: exit $RUN_RC: $(cat "$T/log-d")"
[[ "$(cat "$T/impl-count-d")" -eq 1 ]] || fail "case d: impl ran $(cat "$T/impl-count-d") times, want 1"
[[ "$(cat "$T/gate-claude-count-d")" -eq 2 ]] || fail "case d: gate retry count was not 2"

echo "=== goal entry test still passes ==="
env -u FACTORY_ROOT -u FACTORY_RUNS_DIR -u FACTORY_NOTIFY_DIR -u FACTORY_WORK_DIR \
  bash "$ROOT/local/tests/test_goal_entry.sh"

echo "test_run_feedback: PASS"
