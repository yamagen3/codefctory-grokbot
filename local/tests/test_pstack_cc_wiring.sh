#!/usr/bin/env bash
# Offline wiring: patch insertion, pins, and the SDK overlay module.
# Does not start DSH, Claude, or OpenCode, and does not use credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "test_pstack_cc_wiring: FAIL $*" >&2; exit 1; }

grep -q '79b36d9b53a53c78e5ec26bf6ce7dade76686c87' "$ROOT/bin/factory-pstack-install" \
  || fail "pstack pin changed"
grep -q 'plugin marketplace' "$ROOT/bin/factory-pstack-install" && fail "installer must not add the marketplace plugin"
grep -q 'claude-opus-5-5' "$ROOT/config/factory.patch.yml" || fail "CC model pin missing"
grep -q "CLAUDE_CODE_EFFORT_LEVEL: 'xhigh'" "$ROOT/config/factory.patch.yml" || fail "CC effort pin missing"
grep -q 'permissionMode: acceptEdits' "$ROOT/config/factory.patch.yml" || fail "permissionMode changed"
grep -q 'permissionMode: bypassPermissions' "$ROOT/config/factory.patch.yml" && fail "permissionMode switched to bypass"
grep -q "'@anthropic-ai/claude-agent-sdk': 0.3.318" "$ROOT/config/headless.pnpm-workspace.yaml" \
  || fail "Agent SDK pin changed"
grep -q 'opencode-go/deepseek-v4.1-flash' "$ROOT/bin/factory-common.sh" || fail "OC model default changed"
grep -q 'reasoningEffort": "max"' "$ROOT/bin/factory-common.sh" || fail "OC max effort missing"
grep -q 'auto-apply only small patch/security fixes' "$ROOT/DECISIONS.md" || fail "security-update policy text missing"
grep -q 'pstackQueryOverlay' "$ROOT/scripts/apply-cc-allowlist-patch.sh" || fail "setup patch does not call the overlay"
grep -q '\.\.\.pstackQueryOverlay(),' "$ROOT/plugin/cc-allowlist/vendor/index.js" || fail "vendor query options omit the overlay"

# Re-apply onto a copy of the pre-overlay provider and prove idempotency.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/pkg"
python3 - "$ROOT/plugin/cc-allowlist/vendor/index.js" "$tmp/pkg/index.js" <<'PY'
import pathlib, sys
src, dest = sys.argv[1:]
text = pathlib.Path(src).read_text()
text = text.replace('import { pstackQueryOverlay } from "/workspace/factory/plugin/cc-allowlist/pstack-session.js";\n', '')
old = "\t\t...pstackQueryOverlay(),\n"
if text.count(old) != 1:
    raise SystemExit(f"expected one vendor spread, found {text.count(old)}")
pathlib.Path(dest).write_text(text.replace(old, "", 1))
PY
FACTORY_CC_PATCH_PKG="$tmp/pkg" "$ROOT/scripts/apply-cc-allowlist-patch.sh" >/tmp/pstack-patch-1.txt
grep -q '^applied$' /tmp/pstack-patch-1.txt || fail "first patch apply did not apply"
python3 - "$tmp/pkg/index.js" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert text.count("...pstackQueryOverlay(),") == 1, text.count("...pstackQueryOverlay(),")
assert 'import { pstackQueryOverlay }' in text
# The stock permission branch stays. The overlay does not replace it with bypass.
assert "permissionMode" in text and "bypassPermissions" in text
assert text.count("allowDangerouslySkipPermissions") == 1
PY
before="$(sha256sum "$tmp/pkg/index.js" | awk '{print $1}')"
# Setup restores the stock provider, then applies the same patch again.
FACTORY_CC_PATCH_PKG="$tmp/pkg" "$ROOT/scripts/apply-cc-allowlist-patch.sh" >/tmp/pstack-patch-2.txt
grep -q '^applied$' /tmp/pstack-patch-2.txt || fail "reapply did not rebuild from stock"
after="$(sha256sum "$tmp/pkg/index.js" | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail "reapply output drifted"

node "$ROOT/local/tests/test_pstack_cc_session.mjs"
echo "test_pstack_cc_wiring: PASS"
