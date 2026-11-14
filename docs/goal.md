# SPEC uses Claude Code `/goal`

The SPEC step runs Claude Code `/goal` through the standard CLI: `claude -p "/goal <condition>\n<brief>"`. Claude Code documents that `/goal` works in `-p` mode and keeps taking turns until the condition is met within that one invocation.

The factory no longer runs DSH (removed 2026-11-14). DSH's own `/goal` only armed its dummy parent agent, so it was never used.

## Claude Code `/goal` is the spec prompt

[Claude Code `/goal`](https://code.claude.com/docs/en/goal) sets a completion condition. CC keeps taking turns until an evaluator model judges the condition met or impossible, or an error clears it. The evaluator only reads the transcript, so the condition includes how to prove the work. A clause `or stop after N turns` bounds the loop.

The 2026-11-09 probe sent a bare `/goal` as the CC task and got CC's own reply `No goal set. Usage: /goal <condition>` with 0 model turns. A condition, not a bare `/goal`, is what starts the loop. `factory_cc_spec_prompt` starts the SPEC task with one `/goal` line. That line is the condition: the files to freeze, how to prove them by quoting them, and `or stop after 12 turns`. Claude Code documents a 4,000-character cap on the condition, so the brief is not placed on that line. The full brief and the SPEC instructions follow it, uncut. OpenCode IMPL is unchanged and is not given `/goal`. Whether the CC parser treats only that first line as the condition was not re-checked on the box.

Grok's acceptance tests, via `factory-gate-grok`, remain the factory-wide judgment. The CC goal only steers the spec step.

## Not verified here

Whether the CC parser treats only the first line as the condition was not re-checked. OpenCode has no equivalent command.
