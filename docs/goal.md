# Factory `/goal` convention

Checked against the factory tree, DSH `0.2.2-rc.1`, Claude Code’s `/goal` document, Agent SDK `0.3.319` (`claudeCodeVersion` `2.1.319`), and pstack-claude `79b36d9`. DSH `/goal` and Claude Code `/goal` are real commands. Neither is available as the factory pipeline. The factory spec step calls that command through `ctx.commands.execute`. It is not Claude Code /goal.

## Factory entry that already exists

`bin/factory-run-local <id> <brief...>` is the local start. It requires `FACTORY_TARGET_NAME` and a non-empty brief (unless `FACTORY_SKIP_CC_SPEC=1`). The brief is passed unchanged to `factory-spec-step`, which is the CC spec session. After the local spec tag, the same script runs `factory-impl-step` (OpenCode, parallel count from `spec/IMPL_STRATEGY.md`, fallback 2, cap 4), then guard, ci, `factory-gate-claude`, and `factory-gate-grok`. Local spec freeze is still the automatic tag in that script. Production human approval is unchanged and is not performed here.

`bin/factory-step` launches `dsh --profile headless` with the factory patch. The patch disables `headless-runner`. `plugin/index.js` reads `headlessStartup.task` and sends that string as one text block to a Claude Code or OpenCode subagent. On the spec step it also calls `ctx.commands.execute` for `FACTORY_DSH_GOAL_LINE` before that prompt. The slash line is not the prompt.

## DSH `/goal` (pinned 0.2.2-rc.1)

`@deepseek-ai/dsh-command-goal@0.2.2-rc.1` is a dependency of `@deepseek-ai/dsh-base@0.2.2-rc.1`. The headless profile includes that base. The command’s own README in that version says: “Use this package in interactive deployments with a command adapter; headless and automation apps without one do not need it.” It also says:

- `/goal <objective>` creates and arms a same-session goal in an interactive UI with a command adapter.
- The slash input does not enter the model request.
- Headless, ACP automation, and JSON-RPC adapters do not consume `ctx.commands`. Headless apps without a command adapter do not need this package.

`@deepseek-ai/dsh-headless@0.2.2-rc.1` runs one task and exits. The task is the positional argument or stdin, submitted as an ordinary user message. There is no interactive follow-up. Passing `dsh --profile headless "/goal …"` therefore does not by itself run the command. The factory spec step sets `FACTORY_DSH_GOAL_LINE` and the orchestrator calls `execute`.

## Claude Code `/goal`

[code.claude.com/docs/en/goal](https://code.claude.com/docs/en/goal) and the commands list define `/goal <condition>` as a Claude Code session loop: after each turn a model judges the condition, and Claude continues until it holds, is judged impossible, or an error clears it. `claude -p "/goal …"` is the documented non-interactive CLI form. The factory does not call `claude -p`. It calls Agent SDK `query()` through DSH. SDK `0.3.319`’s changelog does not add `/goal` handling, and a slash prefix in `query()` is not the CLI command path. Using that loop would also keep Claude Code working inside one session instead of spec, then OpenCode implementation, then the gates.

## pstack

The pinned skill list has no `/goal` command. The port’s note on Cursor `/goal` is that it has no Claude Code equivalent inside pstack; that is a separate product from Claude Code’s own `/goal`.

## Supported DSH mechanism

`dsh-base@0.2.2-rc.1` depends on `dsh-commands`, `dsh-command-goal`, and `dsh-goal`. The headless profile includes that base, so the command is registered in the headless process. The headless runner still does not read `ctx.commands`: it publishes the positional task as an ordinary user message. That limit is about the runner, not about whether a plugin can execute the command.

`CommandRuntime.execute(agent, line, attachments, signal)` is the supported call. For `/goal <objective>` the published handler parses the line and calls `ctx.goals.create`. The slash text is not a model prompt. Direct `ctx.goals.create` skips that grammar and is not the path used here. The interactive UI adapter is also not required for `execute`.

`factory-spec-step` sets `FACTORY_DSH_GOAL_LINE="/goal ${BRIEF}"` on the spec `factory-step`. `plugin/index.js` calls `configureDshGoal`, which calls `commands.execute` and then requires the step prompt to contain the stored objective. The rest of `factory-run-local` is unchanged: spec, then OpenCode IMPL, then guard, ci, and both gates.

`dsh-goal-round-driver` is also in `dsh-base`. It queues a parent-model round only while the goal is active and armed. The factory parent is model-less, so after the command succeeds the step calls `ctx.goals.disarm`. That drops process-local continuation and leaves the durable phase and objective. It does not call `/goal pause`.

Claude Code `/goal` is not used.

No newer DSH is required. These symbols are in `0.2.2-rc.1`.

## What a live box still has to show

This test loads the published command module and runs its handler. It does not boot `dsh --profile headless`, so it does not write a session log. On the box, after this tree is deployed, a spec step should log `factory: DSH /goal configured` and the session should contain the goal objective. That process check is not done here.
