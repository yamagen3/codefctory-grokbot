		// factory: Stop hook reports the effort actually applied (after any silent downgrade) to FACTORY_CC_USAGE_FILE.
		hooks: { Stop: [{ hooks: [async (input) => {
			try {
				const usageFile = process.env.FACTORY_CC_USAGE_FILE;
				if (usageFile) {
					const fs = await import("node:fs");
					fs.appendFileSync(usageFile, JSON.stringify({ source: "claude-agent-sdk.stop-hook", effort: input?.effort?.level ?? null }) + "\n");
				}
			} catch {}
			return {};
		}] }] },
