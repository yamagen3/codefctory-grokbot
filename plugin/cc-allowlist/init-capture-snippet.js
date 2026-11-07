		// factory: record the effective model/effort reported by the SDK init message (FACTORY_CC_USAGE_FILE).
		if (message.type === "system" && message.subtype === "init") {
			try {
				const usageFile = process.env.FACTORY_CC_USAGE_FILE;
				if (usageFile) {
					const fs = await import("node:fs");
					fs.appendFileSync(usageFile, JSON.stringify({
						source: "claude-agent-sdk.init",
						model: message.model ?? null,
						effort: message.effort ?? null,
						claude_code_version: message.claude_code_version ?? null
					}) + "\n");
				}
			} catch {}
		}
