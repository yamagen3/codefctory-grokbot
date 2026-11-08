#!/usr/bin/env bash
# The factory start stays factory-run-local. /goal is not given a new meaning.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "test_goal_entry: FAIL $*" >&2; exit 1; }

[[ ! -e "$ROOT/bin/factory-goal" ]] || fail "bin/factory-goal exists; that command was not a documented factory entry"
grep -q 'factory-spec-step "$WORK" "$ID" "$BRIEF"' "$ROOT/bin/factory-run-local" \
  || fail "run-local no longer passes the brief to spec"
grep -q 'factory-impl-step' "$ROOT/bin/factory-run-local" || fail "run-local no longer runs impl"
grep -q 'factory-gate-claude' "$ROOT/bin/factory-run-local" || fail "run-local no longer runs gate/claude"
grep -q 'headless and automation apps without one do not need it' "$ROOT/docs/goal.md" \
  || fail "goal doc lost the pinned DSH limitation"
grep -q 'does not add a `/goal` entry' "$ROOT/docs/goal.md" || fail "goal doc no longer records the non-decision"

set +e
out=$(FACTORY_TARGET_NAME=example "$ROOT/bin/factory-run-local" only-id 2>&1)
ec=$?
set -e
[[ "$ec" -ne 0 ]] || fail "run-local accepted a start with no brief"
printf '%s\n' "$out" | grep -q 'brief' || fail "run-local error did not mention brief: $out"

# A brief must not be rewritten into a slash command before spec sees it.
# The usage check above returns before any origin. This grep locks the call shape.
grep -q 'factory-spec-step "$WORK" "$ID" "$BRIEF"' "$ROOT/bin/factory-run-local"
echo "test_goal_entry: PASS"
