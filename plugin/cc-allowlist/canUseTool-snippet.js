		...spec.permissionMode === "bypassPermissions" && !(process.env.FACTORY_CC_STEP || (spec.env && spec.env.FACTORY_CC_STEP)) ? { allowDangerouslySkipPermissions: true } : { canUseTool: async (toolName, input) => {
			const step = process.env.FACTORY_CC_STEP || (spec.env && spec.env.FACTORY_CC_STEP) || "";
			try {
				const fs = await import("node:fs");
				fs.appendFileSync("/tmp/cc-allowlist-decisions.log", JSON.stringify({ phase: "enter", step, toolName, envStep: process.env.FACTORY_CC_STEP || null, specEnvStep: (spec.env && spec.env.FACTORY_CC_STEP) || null, perm: spec.permissionMode }) + "\n");
			} catch {}
			if (!step) {
				captureDiagnostic(unattendedDiagnostic(spec.permissionMode, "tool permission", "denied", "the provider does not request human approval"));
				return {
					behavior: "deny",
					message: "This unattended Claude Code subagent cannot request human approval."
				};
			}
			try {
				const { makeCanUseTool } = await import("__FACTORY_ROOT__/plugin/cc-allowlist/allowlist.js");
				const decide = makeCanUseTool(step, spec.cwd);
				const result = await decide(toolName, input);
				if (result.behavior === "deny") {
					captureDiagnostic(unattendedDiagnostic(spec.permissionMode, "tool permission", "denied", result.message || "allowlist"));
				}
				return result;
			} catch (error) {
				captureDiagnostic(unattendedDiagnostic(spec.permissionMode, "tool permission", "denied", String(error?.message || error)));
				return { behavior: "deny", message: "factory allowlist handler failed" };
			}
		} },
