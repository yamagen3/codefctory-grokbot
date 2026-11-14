#!/usr/bin/env bash
# SPEC prompt is Claude Code /goal, passed as the `claude -p` prompt. No DSH.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/bin/factory-common.sh"
fail() { echo "test_goal_entry: FAIL $*" >&2; exit 1; }

BRIEF='DeepSeek max setting persists after reprovision, and the spec names the proof.'
prompt="$(factory_cc_spec_prompt "$BRIEF" "example-cli")"
[[ "$prompt" == "/goal "* ]] || fail "spec prompt does not start with /goal: ${prompt:0:40}"
first="${prompt%%$'\n'*}"
[[ "$first" == *'Or stop after 12 turns.' ]] || fail "missing turn bound on the goal line"
[[ "$first" == *'Prove it by quoting'* ]] || fail "missing proof clause on the goal line"
[[ "${#first}" -le 4000 ]] || fail "goal condition is ${#first} characters"
printf '%s\n' "$prompt" | grep -q 'spec/PRODUCT.md' || fail "missing product spec path"
printf '%s\n' "$prompt" | grep -q 'parallel: N' || fail "missing parallel condition"
printf '%s\n' "$prompt" | grep -qF "Brief: ${BRIEF}" || fail "brief not available to CC"
# A long brief stays intact and is not part of the /goal condition line.
long="$(python3 -c 'print("Y"*2500)')"
long_prompt="$(factory_cc_spec_prompt "$long" "example-cli")"
long_first="${long_prompt%%$'\n'*}"
[[ "$long_first" == "$first" ]] || fail "long brief changed the /goal condition"
[[ "${#long_first}" -le 4000 ]] || fail "long brief inflated the condition to ${#long_first}"
printf '%s\n' "$long_prompt" | grep -qF "Brief: ${long}" || fail "long brief was truncated"

grep -q 'factory_cc_spec_prompt' "$ROOT/bin/factory-spec-step" || fail "spec step does not use the prompt"
grep -q 'factory-spec-step "$WORK" "$ID" "$BRIEF"' "$ROOT/bin/factory-run-local" \
  || fail "run-local no longer passes the brief to spec"
grep -q 'factory-impl-step' "$ROOT/bin/factory-run-local" || fail "run-local no longer runs impl"
grep -q 'factory-gate-grok' "$ROOT/bin/factory-run-local" || fail "run-local no longer runs gate/grok"
# IMPL prompt is not a CC /goal.
grep -q '^/goal ' "$ROOT/bin/factory-impl-step" && fail "impl step starts with /goal" || true
# The runner hands the task to `claude -p` as the prompt, so /goal is expanded by Claude Code.
grep -q '"-p", task' "$ROOT/lib/factory_step.py" || fail "runner does not pass the task as the claude -p prompt"
[[ ! -e "$ROOT/plugin" ]] || fail "DSH plugin directory still present"
[[ ! -e "$ROOT/config/factory.patch.yml" ]] || fail "DSH patch still present"
if grep -rqE '\bdsh (--profile|plugin)' "$ROOT/bin" "$ROOT/lib"; then
  fail "a factory script still invokes dsh"
fi
[[ ! -e "$ROOT/bin/factory-goal" ]] || fail "factory-goal substitute still present"

set +e
empty=$(factory_cc_spec_prompt "" 2>&1)
ec=$?
set -e
[[ "$ec" -ne 0 ]] || fail "empty brief was accepted"
echo "test_goal_entry: PASS"
