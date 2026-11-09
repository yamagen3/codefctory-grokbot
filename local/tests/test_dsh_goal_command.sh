#!/usr/bin/env bash
# Native DSH /goal handler from the pinned package, then the factory supply check.
# Installs the published package into a temp prefix. No model and no credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "test_dsh_goal_command: FAIL $*" >&2; exit 1; }

[[ ! -e "$ROOT/bin/factory-goal" ]] || fail "factory-goal substitute is still present"
grep -q 'FACTORY_DSH_GOAL_LINE="/goal ${BRIEF}"' "$ROOT/bin/factory-spec-step" \
  || fail "spec step does not pass a DSH /goal line"
grep -q 'configureDshGoal' "$ROOT/plugin/index.js" || fail "orchestrator does not call configureDshGoal"
grep -q 'ctx.commands.execute' "$ROOT/docs/goal.md" || fail "docs do not name the native execute API"

prefix="$(mktemp -d)"
trap 'rm -rf "$prefix"' EXIT
npm install --prefix "$prefix" --no-audit --no-fund --legacy-peer-deps \
  @deepseek-ai/dsh-command-goal@0.2.2-rc.1 \
  @deepseek-ai/dsh-commands@0.2.2-rc.1 >/tmp/factory-dsh-goal-install.txt
pkg="$prefix/node_modules/@deepseek-ai/dsh-command-goal"
[[ -f "$pkg/lib/index.js" ]] || fail "pinned command-goal package missing"
[[ "$(node -p "require('$pkg/package.json').version")" == "0.2.2-rc.1" ]] || fail "command-goal version drifted"

FACTORY_DSH_COMMAND_GOAL="$pkg" \
  node --import "$ROOT/local/tests/register-dsh-command-goal.mjs" \
  "$ROOT/local/tests/test_dsh_goal_command.mjs"
echo "test_dsh_goal_command: PASS"
