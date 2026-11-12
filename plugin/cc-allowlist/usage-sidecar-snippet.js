		onResult?.();
		// factory: usage sidecar. DSH keeps only result text; record the SDK's own usage numbers
		// (modelUsage/usage/total_cost_usd) to $FACTORY_CC_USAGE_FILE before strict success checks.
		try {
			const usageFile = process.env.FACTORY_CC_USAGE_FILE;
			if (usageFile) {
				const fs = await import("node:fs");
				fs.appendFileSync(usageFile, JSON.stringify({
					source: "claude-agent-sdk.result",
					subtype: message.subtype,
					stop_reason: message.stop_reason ?? null,
					num_turns: message.num_turns ?? null,
					duration_ms: message.duration_ms ?? null,
					duration_api_ms: message.duration_api_ms ?? null,
					total_cost_usd: message.total_cost_usd ?? null,
					usage: message.usage ?? null,
					modelUsage: message.modelUsage ?? null,
					is_error: message.is_error ?? null,
					terminal_reason: message.terminal_reason ?? null,
					api_error_status: message.api_error_status ?? null,
					api_error: message.api_error ?? null,
					result_head: typeof message.result === "string" ? message.result.slice(0, 300) : null
				}) + "\n");
			}
		} catch {}
		answer = successfulResult(message);
