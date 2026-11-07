# P2 — Claude Code via factory-orchestrator (no DSH model key)

Stock `dsh headless` uses DeepSeek as orchestrator. The factory plugin **replaces**
`headless-runner` and drives Claude Code through `ctx.subagents.startActivation`
(design.md §11). **No `DEEPSEEK_API_KEY`.**

## One-command smoke test (when `CLAUDE_CODE_OAUTH_TOKEN` is set)

```bash
export PATH="/workspace/factory/bin:$HOME/.local/bin:$PATH"
mkdir -p /tmp/factory-p2-cc && cd /tmp/factory-p2-cc
# ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN are stripped by factory-step.
factory-step --json 'Reply with exactly the single word pong and nothing else.'
```

Expect JSON on stdout with `"stopReason":"completed"` and text/`output` containing `pong`; exit 0.

## Without a token (P1 check)

```bash
env -u CLAUDE_CODE_OAUTH_TOKEN -u DEEPSEEK_API_KEY -u ANTHROPIC_API_KEY \
  factory-step --json 'ping'
```

Expect: **no** `MISSING_CREDENTIAL` for `deepseek-official`; failure at CC auth / product start; **nonzero** exit.
