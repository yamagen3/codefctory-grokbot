#!/usr/bin/env bash
# SPEC prompt is Claude Code /goal. DSH commands/goals are not touched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/bin/factory-common.sh"
fail() { echo "test_goal_entry: FAIL $*" >&2; exit 1; }

BRIEF='DeepSeek max setting persists after reprovision, and the spec names the proof.'
prompt="$(factory_cc_spec_prompt "$BRIEF" "example-cli")"
[[ "$prompt" == "/goal "* ]] || fail "spec prompt does not start with /goal: ${prompt:0:40}"
printf '%s\n' "$prompt" | grep -q 'or stop after 12 turns' || fail "missing turn bound"
printf '%s\n' "$prompt" | grep -q 'Prove it in the final reply' || fail "missing proof clause"
printf '%s\n' "$prompt" | grep -q 'spec/PRODUCT.md' || fail "missing product spec path"
printf '%s\n' "$prompt" | grep -q 'parallel: N' || fail "missing parallel condition"
printf '%s\n' "$prompt" | grep -qF "Brief: ${BRIEF}" || fail "brief not available to CC"

grep -q 'factory_cc_spec_prompt' "$ROOT/bin/factory-spec-step" || fail "spec step does not use the prompt"
grep -q 'factory-spec-step "$WORK" "$ID" "$BRIEF"' "$ROOT/bin/factory-run-local" \
  || fail "run-local no longer passes the brief to spec"
grep -q 'factory-impl-step' "$ROOT/bin/factory-run-local" || fail "run-local no longer runs impl"
grep -q 'factory-gate-grok' "$ROOT/bin/factory-run-local" || fail "run-local no longer runs gate/grok"
# IMPL prompt is not a CC /goal.
grep -q '^/goal ' "$ROOT/bin/factory-impl-step" && fail "impl step starts with /goal" || true
if grep -qE 'ctx\.commands|ctx\.goals|configureDshGoal|FACTORY_DSH_GOAL_LINE' "$ROOT/plugin/index.js"; then
  fail "orchestrator still depends on DSH goal services"
fi
grep -q "inject = \['agents', 'subagents'\]" "$ROOT/plugin/index.js" \
  || fail "inject list changed"
[[ ! -e "$ROOT/plugin/dsh-goal.js" ]] || fail "dsh-goal.js still present"
[[ ! -e "$ROOT/bin/factory-goal" ]] || fail "factory-goal substitute still present"

set +e
empty=$(factory_cc_spec_prompt "" 2>&1)
ec=$?
set -e
[[ "$ec" -ne 0 ]] || fail "empty brief was accepted"
echo "test_goal_entry: PASS"
