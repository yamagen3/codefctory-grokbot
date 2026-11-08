#!/usr/bin/env bash
# Source proof: the provision writer restores reasoningEffort=max.
# The box script that still writes model+permission only is the deployment gap.
# No sudo, network, or credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/bin/factory-common.sh"
fail() { echo "test_oc_reprovision_keeps_max: FAIL $*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cfg="$tmp/opencode.json"

# Document the box still writes today: model + permission, no providers.
printf '%s\n' '{
  "$schema": "https://opencode.ai/config.json",
  "model": "opencode-go/deepseek-v4.1-flash",
  "permission": { "*": "allow" }
}' > "$cfg"
set +e
before=$(factory_oc_config_problems < "$cfg" 2>&1)
before_ec=$?
set -e
[[ "$before_ec" -ne 0 ]] || fail "max-less file was accepted"
printf '%s\n' "$before" | grep -q 'reasoningEffort' || fail "max-less file was not reported: $before"

status=$(FACTORY_OC_MODEL=opencode-go/deepseek-v4.1-flash "$ROOT/bin/factory-oc-provision" --apply-config "$cfg")
[[ "$status" == wrote ]] || fail "apply-config did not replace the max-less file: $status"
factory_oc_config_problems < "$cfg" || fail "reprovision result lost max"

again=$(FACTORY_OC_MODEL=opencode-go/deepseek-v4.1-flash "$ROOT/bin/factory-oc-provision" --apply-config "$cfg")
[[ "$again" == unchanged ]] || fail "second reprovision rewrote an already-correct file: $again"
factory_oc_config_problems < "$cfg" || fail "second reprovision dropped max"
grep -q 'factory_oc_write_config' "$ROOT/bin/factory-oc-provision" \
  || fail "live provision path does not use factory_oc_write_config"
echo "test_oc_reprovision_keeps_max: PASS"
