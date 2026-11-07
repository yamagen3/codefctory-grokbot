#!/usr/bin/env bash
set -euo pipefail
PKG="${FACTORY_CC_PATCH_PKG:-/home/box/.dsh/profiles/headless/node_modules/@deepseek-ai/dsh-subagent-claude-code/lib}"
export FACTORY_CC_PATCH_INDEX="${FACTORY_CC_PATCH_INDEX:-$PKG/index.js}"
[[ -f "$PKG/index.js.stock" ]] || cp "$PKG/index.js" "$PKG/index.js.stock"
cp "$PKG/index.js.stock" "$PKG/index.js"
python3 <<'PY'
import os
from pathlib import Path
p = Path(os.environ["FACTORY_CC_PATCH_INDEX"])
snip = Path("/workspace/factory/plugin/cc-allowlist")

def apply_base(t):
    old = '''\t\t...spec.permissionMode === "bypassPermissions" ? { allowDangerouslySkipPermissions: true } : { canUseTool: () => {
\t\t\tcaptureDiagnostic(unattendedDiagnostic(spec.permissionMode, "tool permission", "denied", "the provider does not request human approval"));
\t\t\treturn Promise.resolve({
\t\t\t\tbehavior: "deny",
\t\t\t\tmessage: "This unattended Claude Code subagent cannot request human approval."
\t\t\t});
\t\t} },'''
    new = (snip / "canUseTool-snippet.js").read_text()
    if old not in t:
        raise SystemExit("stock canUseTool block not found")
    t = t.replace(old, new)
    # usage sidecar (factory-usage): stock drops the SDK result's usage; write it to FACTORY_CC_USAGE_FILE
    uold = "\t\tonResult?.();\n\t\tanswer = successfulResult(message);\n"
    if uold not in t:
        raise SystemExit("stock consumeClaudeQuery result block not found")
    t = t.replace(uold, (snip / "usage-sidecar-snippet.js").read_text())
    # init capture (factory-usage): effective model + effort after any silent downgrade
    iold = '\t\tif (message.type !== "result") continue;\n'
    if iold not in t:
        raise SystemExit("stock consumeClaudeQuery result filter not found")
    t = t.replace(iold, (snip / "init-capture-snippet.js").read_text() + iold, 1)
    # effort (factory pin): pass SDK Options.effort from the provider env so it is explicit, not env-only
    eold = '\t\t...spec.model === void 0 ? {} : { model: spec.model },\n'
    if t.count(eold) != 1:
        raise SystemExit("stock claudeQueryOptions model line not found")
    if "CLAUDE_CODE_EFFORT_LEVEL" not in t:
        t = t.replace(
            eold,
            eold + '\t\t...(spec.env && spec.env.CLAUDE_CODE_EFFORT_LEVEL) ? { effort: spec.env.CLAUDE_CODE_EFFORT_LEVEL } : {},\n'
            + (snip / "effort-hook-snippet.js").read_text(),
            1,
        )
    return t

def apply_pstack(t):
    # User skill source + stage bootstrap. The env anchor exists in stock and in the older factory patch.
    ianchor = 'import { query } from "@anthropic-ai/claude-agent-sdk";\n'
    if ianchor not in t:
        raise SystemExit("sdk import anchor missing")
    t = t.replace(
        ianchor,
        ianchor + 'import { pstackQueryOverlay } from "/workspace/factory/plugin/cc-allowlist/pstack-session.js";\n',
        1,
    )
    eanchor = "\t\tenv: {\n\t\t\t...scrubbedParentEnv(),\n"
    if t.count(eanchor) != 1:
        raise SystemExit("claudeQueryOptions env anchor missing")
    return t.replace(eanchor, "\t\t...pstackQueryOverlay(),\n" + eanchor, 1)

t = p.read_text()
base_ready = "makeCanUseTool" in t and "FACTORY_CC_STEP" in t
if base_ready and "pstackQueryOverlay" in t:
    print("already patched")
    raise SystemExit(0)
if not base_ready:
    t = apply_base(t)
if "pstackQueryOverlay" not in t:
    t = apply_pstack(t)
p.write_text(t)
print("applied")
PY
