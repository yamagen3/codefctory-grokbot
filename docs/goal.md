# SPEC uses Claude Code `/goal`

Box trials on 2026-11-09 (DSH 0.2.2-rc.1, Agent SDK 0.3.319) showed two different `/goal` commands.

## DSH `/goal` is not used

`dsh-command-goal` registers a goal on the DSH parent agent. Claude Code (Agent SDK `query`) and OpenCode (ACP) do not receive that goal. While it is armed, `dsh-goal-round-driver` tries to run the dummy parent model. The factory parent has no working credential, so the driver fails and disarms. Disarmed, it does nothing for CC or OpenCode.

`plugin/index.js` does not read `ctx.commands` or `ctx.goals`. Its `inject` list stays `agents` and `subagents`. Cordis throws `cannot get property "commands" without inject` if those properties are read without inject; that path is gone.

## Claude Code `/goal` is the spec prompt

[Claude Code `/goal`](https://code.claude.com/docs/en/goal) sets a completion condition. CC keeps taking turns until an evaluator model judges the condition met or impossible, or an error clears it. The evaluator only reads the transcript, so the condition includes how to prove the work. A clause `or stop after N turns` bounds the loop.

The 2026-11-09 probe sent a bare `/goal` as the CC task through DSH and got CC's own reply `No goal set. Usage: /goal <condition>` with 0 model turns. A condition, not a bare `/goal`, is what starts the loop. `factory_cc_spec_prompt` starts the SPEC task with one `/goal` line. That line is the condition: the files to freeze, how to prove them by quoting them, and `or stop after 12 turns`. Claude Code documents a 4,000-character cap on the condition, so the brief is not placed on that line. The full brief and the SPEC instructions follow it, uncut. OpenCode IMPL is unchanged and is not given `/goal`. Whether the CC parser treats only that first line as the condition was not re-checked on the box.

Grok's acceptance tests, via `factory-gate-grok`, remain the factory-wide judgment. The CC goal only steers the spec step.

## Not verified here

Agent SDK queries in this factory set `persistSession: false`. Whether CC `/goal` still takes multiple turns in that mode was not run in this checkout. OpenCode has no equivalent command.
