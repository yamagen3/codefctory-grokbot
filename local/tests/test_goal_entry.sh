#!/usr/bin/env bash
# factory-goal is the factory convention. It is not DSH /goal or Claude Code /goal.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "test_goal_entry: FAIL $*" >&2; exit 1; }

GOAL='DeepSeek max setting persists after reprovision, and factory /goal entry is established and verified.'
[[ -x "$ROOT/bin/factory-goal" ]] || fail "factory-goal missing"
grep -q 'exec "$(cd "$(dirname "$0")" && pwd)/factory-run-local"' "$ROOT/bin/factory-goal" \
  || fail "factory-goal does not exec factory-run-local"
grep -q 'factory-spec-step "$WORK" "$ID" "$BRIEF"' "$ROOT/bin/factory-run-local" \
  || fail "run-local no longer passes the brief to spec"
grep -q 'factory-impl-step' "$ROOT/bin/factory-run-local" || fail "run-local no longer runs impl"
grep -q 'factory-gate-claude' "$ROOT/bin/factory-run-local" || fail "run-local no longer runs gate/claude"
grep -q 'headless and automation apps without one do not need it' "$ROOT/docs/goal.md" \
  || fail "goal doc lost the pinned DSH limitation"
grep -q 'not a native DSH or Claude Code /goal invocation' "$ROOT/docs/goal.md" \
  || fail "goal doc claims a native invocation"
# The script must not launch dsh or claude itself.
grep -E 'dsh |claude -p' "$ROOT/bin/factory-goal" && fail "factory-goal calls dsh or claude" || true

out=$(FACTORY_GOAL_PRINT=1 "$ROOT/bin/factory-goal" goal-1 "$GOAL")
printf '%s\n' "$out" | grep -qx "id=goal-1" || fail "id not preserved: $out"
printf '%s\n' "$out" | grep -qx "objective=${GOAL}" || fail "objective rewritten: $out"
printf '%s\n' "$out" | grep -qx 'pipeline=factory-run-local' || fail "pipeline not factory-run-local: $out"

set +e
empty=$(FACTORY_GOAL_PRINT=1 "$ROOT/bin/factory-goal" goal-1 2>&1)
ec=$?
set -e
[[ "$ec" -ne 0 ]] || fail "empty objective was accepted: $empty"

set +e
nobrief=$(FACTORY_TARGET_NAME=example "$ROOT/bin/factory-run-local" only-id 2>&1)
ec=$?
set -e
[[ "$ec" -ne 0 ]] || fail "run-local accepted a start with no brief"
printf '%s\n' "$nobrief" | grep -q 'brief' || fail "run-local error did not mention brief: $nobrief"
echo "test_goal_entry: PASS"
