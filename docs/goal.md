# Factory `/goal` convention

Checked against the factory tree, DSH `0.2.2-rc.1`, Claude Code’s `/goal` document, Agent SDK `0.3.319` (`claudeCodeVersion` `2.1.319`), and pstack-claude `79b36d9`. DSH `/goal` and Claude Code `/goal` are real commands. Neither is available as the factory pipeline. `bin/factory-goal` is the factory convention for that pipeline. It is not a native DSH or Claude Code /goal invocation.

## Factory entry that already exists

`bin/factory-run-local <id> <brief...>` is the local start. It requires `FACTORY_TARGET_NAME` and a non-empty brief (unless `FACTORY_SKIP_CC_SPEC=1`). The brief is passed unchanged to `factory-spec-step`, which is the CC spec session. After the local spec tag, the same script runs `factory-impl-step` (OpenCode, parallel count from `spec/IMPL_STRATEGY.md`, fallback 2, cap 4), then guard, ci, `factory-gate-claude`, and `factory-gate-grok`. Local spec freeze is still the automatic tag in that script. Production human approval is unchanged and is not performed here.

`bin/factory-step` launches `dsh --profile headless` with the factory patch. The patch disables `headless-runner`. `plugin/index.js` reads `headlessStartup.task` and sends that string as one text block to a Claude Code or OpenCode subagent. It does not call a command registry.

## DSH `/goal` (pinned 0.2.2-rc.1)

`@deepseek-ai/dsh-command-goal@0.2.2-rc.1` is a dependency of `@deepseek-ai/dsh-base@0.2.2-rc.1`. The headless profile includes that base. The command’s own README in that version says: “Use this package in interactive deployments with a command adapter; headless and automation apps without one do not need it.” It also says:

- `/goal <objective>` creates and arms a same-session goal in an interactive UI with a command adapter.
- The slash input does not enter the model request.
- Headless, ACP automation, and JSON-RPC adapters do not consume `ctx.commands`. Headless apps without a command adapter do not need this package.

`@deepseek-ai/dsh-headless@0.2.2-rc.1` runs one task and exits. The task is the positional argument or stdin, submitted as an ordinary user message. There is no interactive follow-up. Under the factory patch that message never reaches the DSH model: the orchestrator copies it into one subagent prompt.

So `dsh --profile headless "/goal …"` on this factory is not the DSH goal command. It would be one CC or OC prompt whose text starts with `/goal`.

## Claude Code `/goal`

[code.claude.com/docs/en/goal](https://code.claude.com/docs/en/goal) and the commands list define `/goal <condition>` as a Claude Code session loop: after each turn a model judges the condition, and Claude continues until it holds, is judged impossible, or an error clears it. `claude -p "/goal …"` is the documented non-interactive CLI form. The factory does not call `claude -p`. It calls Agent SDK `query()` through DSH. SDK `0.3.319`’s changelog does not add `/goal` handling, and a slash prefix in `query()` is not the CLI command path. Using that loop would also keep Claude Code working inside one session instead of spec, then OpenCode implementation, then the gates.

## pstack

The pinned skill list has no `/goal` command. The port’s note on Cursor `/goal` is that it has no Claude Code equivalent inside pstack; that is a separate product from Claude Code’s own `/goal`.

## Factory convention entry

`bin/factory-goal <id> <objective...>` is the standard start. It execs `factory-run-local` with that id and the objective as the brief. It does not call `dsh`, `ctx.commands`, or `claude -p`. `FACTORY_GOAL_PRINT=1` prints `id`, `objective`, and `pipeline=factory-run-local` and does not run. `FACTORY_TARGET_NAME` is still required when the pipeline actually runs. An empty objective is rejected.

The objective is plain text, including when it contains the characters `/goal`. Example, which is also the agreed acceptance sentence for this change:

```text
factory-goal <id> DeepSeek max setting persists after reprovision, and factory /goal entry is established and verified.
```

`factory-run-local` remains the pipeline. The native commands below are not used.

## Native commands that were not invoked

1. DSH interactive `/goal`. Headless does not dispatch it, and the factory patch does not mount a command adapter.
2. `claude -p "/goal <condition>"`. That is a Claude Code completion loop, not spec → OpenCode → gates.
