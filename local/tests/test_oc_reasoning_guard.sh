#!/usr/bin/env bash
# Offline: missing OpenCode max is rejected. No network, sudo, or credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/bin/factory-common.sh"
fail() { echo "test_oc_reasoning_guard: FAIL $*" >&2; exit 1; }

good="$("$ROOT/bin/factory-oc-provision" --print-config)"
printf '%s' "$good" | factory_oc_config_problems >/tmp/oc-guard-good.txt && true
[[ $? -eq 0 ]] || fail "provision default was rejected: $(cat /tmp/oc-guard-good.txt)"

check_bad() {
  local label="$1" json="$2" expect="$3"
  local out ec
  set +e
  out=$(printf '%s' "$json" | factory_oc_config_problems 2>&1)
  ec=$?
  set -e
  [[ "$ec" -ne 0 ]] || fail "$label was accepted"
  printf '%s' "$out" | grep -q "$expect" || fail "$label message was: $out"
}

check_bad missing-effort '{"model":"opencode-go/deepseek-v4.1-flash","permission":{"*":"allow"}}' 'reasoningEffort'
check_bad wrong-effort '{"model":"opencode-go/deepseek-v4.1-flash","providers":{"opencode-go":{"models":{"deepseek-v4.1-flash":{"settings":{"reasoningEffort":"high"}}}}}}' 'high'
check_bad wrong-model '{"model":"opencode-go/deepseek-v4.1-flash-max","providers":{"opencode-go":{"models":{"deepseek-v4.1-flash":{"settings":{"reasoningEffort":"max"}}}}}}' 'model is'
grep -q 'live OC config lost reasoningEffort=max' "$ROOT/bin/factory-doctor" || fail "doctor does not fail a live config that lost max"
grep -q 'live OC opencode.json missing' "$ROOT/bin/factory-doctor" || fail "doctor does not fail a missing live config"
echo "test_oc_reasoning_guard: PASS"
