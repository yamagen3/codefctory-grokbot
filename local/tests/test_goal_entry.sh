#!/usr/bin/env bash
# The spec step supplies the brief through DSH /goal, then the existing pipeline.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "test_goal_entry: FAIL $*" >&2; exit 1; }

[[ ! -e "$ROOT/bin/factory-goal" ]] || fail "shell /goal substitute exists"
grep -q 'factory-spec-step "$WORK" "$ID" "$BRIEF"' "$ROOT/bin/factory-run-local" \
  || fail "run-local no longer passes the brief to spec"
grep -q 'factory-impl-step' "$ROOT/bin/factory-run-local" || fail "run-local no longer runs impl"
grep -q 'factory-gate-claude' "$ROOT/bin/factory-run-local" || fail "run-local no longer runs gate/claude"
grep -q 'FACTORY_DSH_GOAL_LINE="/goal ${BRIEF}"' "$ROOT/bin/factory-spec-step" \
  || fail "spec does not configure DSH /goal from the brief"
grep -q 'headless and automation apps without one do not need it' "$ROOT/docs/goal.md" \
  || fail "goal doc lost the pinned command README limit"
grep -q 'not Claude Code /goal' "$ROOT/docs/goal.md" || fail "goal doc conflates Claude /goal"

set +e
out=$(FACTORY_TARGET_NAME=example "$ROOT/bin/factory-run-local" only-id 2>&1)
ec=$?
set -e
[[ "$ec" -ne 0 ]] || fail "run-local accepted a start with no brief"
printf '%s\n' "$out" | grep -q 'brief' || fail "run-local error did not mention brief: $out"
echo "test_goal_entry: PASS"
