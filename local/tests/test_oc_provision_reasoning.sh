#!/usr/bin/env bash
# Offline regression: provisioning defaults persist OpenCode reasoningEffort=max.
# Does not call OpenCode, sudo, or the network. No credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/bin/factory-common.sh"

fail() { echo "test_oc_provision_reasoning: FAIL $*" >&2; exit 1; }

assert_json() {
  local label="$1" json="$2" expect_effort="$3"
  python3 - "$label" "$json" "$expect_effort" <<'PY'
import json, sys
label, raw, expect = sys.argv[1], sys.argv[2], sys.argv[3]
doc = json.loads(raw)
model = doc.get("model")
if not isinstance(model, str) or "/" not in model or "#" in model:
    raise SystemExit(f"{label}: model must be provider/model without a variant: {model!r}")
if model.endswith("-max") or "flash-max" in model or model.endswith("#max"):
    raise SystemExit(f"{label}: max must not be encoded in the model id: {model!r}")
if "deepseek-v4.1-flash-max" in raw:
    raise SystemExit(f"{label}: separate -max model id leaked into the document")
perm = doc.get("permission")
if perm != {"*": "allow"}:
    raise SystemExit(f"{label}: permission changed: {perm!r}")
if doc.get("$schema") != "https://opencode.ai/config.json":
    raise SystemExit(f"{label}: schema url changed")
providers = doc.get("providers")
if expect == "max":
    if model != "opencode-go/deepseek-v4.1-flash":
        raise SystemExit(f"{label}: default model drifted: {model!r}")
    if set(doc) != {"$schema", "model", "permission", "providers"}:
        raise SystemExit(f"{label}: unexpected top-level keys: {sorted(doc)}")
    if "provider" in doc:
        raise SystemExit(f"{label}: deprecated singular provider key")
    effort = (
        providers.get("opencode-go", {})
        .get("models", {})
        .get("deepseek-v4.1-flash", {})
        .get("settings", {})
        .get("reasoningEffort")
    )
    if effort != "max":
        raise SystemExit(f"{label}: reasoningEffort={effort!r}")
    if list(providers) != ["opencode-go"]:
        raise SystemExit(f"{label}: unexpected providers: {list(providers)}")
    models = providers["opencode-go"]["models"]
    if list(models) != ["deepseek-v4.1-flash"]:
        raise SystemExit(f"{label}: unexpected models: {list(models)}")
else:
    if "providers" in doc or "reasoningEffort" in raw:
        raise SystemExit(f"{label}: unverified model must not gain reasoningEffort")
    if set(doc) != {"$schema", "model", "permission"}:
        raise SystemExit(f"{label}: override document shape changed: {sorted(doc)}")
print(f"ok {label}")
PY
}

default_json="$(factory_oc_opencode_json)"
assert_json default "$default_json" max

printed="$(FACTORY_OC_MODEL= "$ROOT/bin/factory-oc-provision" --print-config)"
[[ "$printed" == "$default_json" ]] || fail "provision --print-config drifted from factory_oc_opencode_json"

explicit="$(FACTORY_OC_MODEL=opencode-go/deepseek-v4.1-flash "$ROOT/bin/factory-oc-provision" --print-config)"
[[ "$explicit" == "$default_json" ]] || fail "explicit default model drifted"

override="$(FACTORY_OC_MODEL=opencode-go/deepseek-v4-pro "$ROOT/bin/factory-oc-provision" --print-config)"
assert_json override "$override" none
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["model"]=="opencode-go/deepseek-v4-pro"' "$override"

# The provisioner must compare the on-disk file to this same document, so a
# rebuild does not drop max. Slot homes inherit by copying that directory.
grep -q 'factory_oc_write_config' "$ROOT/bin/factory-oc-provision" \
  || fail "provisioner does not write through factory_oc_write_config"
grep -q 'factory_oc_opencode_json' "$ROOT/bin/factory-common.sh" \
  || fail "config writer does not build factory_oc_opencode_json"
grep -q 'sudo -n cp -a /home/factory-oc/.config/opencode/. "$dest/.config/opencode/"' \
  "$ROOT/bin/factory-impl-step" \
  || fail "seed_oc_home no longer copies the shared OpenCode config"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/shared" "$tmp/slot/.config/opencode"
printf '%s' "$default_json" > "$tmp/shared/opencode.json"
cp -a "$tmp/shared/." "$tmp/slot/.config/opencode/"
copied="$(cat "$tmp/slot/.config/opencode/opencode.json")"
[[ "$copied" == "$default_json" ]] || fail "slot copy dropped reasoningEffort"
assert_json slot-copy "$copied" max

# Security-update policy text stays the approved 2026-11-05 rule.
grep -q 'auto-apply only small patch/security fixes' "$ROOT/DECISIONS.md" \
  || fail "security-update policy text missing"

echo "test_oc_provision_reasoning: PASS"
