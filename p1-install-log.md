# P1 install log — DSH / OpenCode / agmsg

Date: 2026-11-03 (Asia/Tokyo)

## Environment

- Linux x86_64, user `box`, node v24.22.1, npm 11.21.1
- npm global prefix: `/home/box/.local` (bins in `/home/box/.local/bin`)
- PATH additions in `~/.bashrc`: `$HOME/.npm-global/bin`, `$HOME/.local/bin`

## Commands used

```bash
# sqlite3 (apt mirrors returned 500; used official tools zip instead)
curl -fsSL -o /tmp/sqlite-tools.zip \
  https://www.sqlite.org/2026/sqlite-tools-linux-x64-3540100.zip
unzip -o /tmp/sqlite-tools.zip -d /tmp/sqlite-tools
cp /tmp/sqlite-tools/sqlite3 /home/box/.local/bin/sqlite3

# npm globals (postinstall scripts allowed)
npm install -g --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs \
  @deepseek-ai/dsh@0.2.1-rc.5
npm install -g --allow-scripts=@opencode/cli @opencode/cli@latest
npm install -g agmsg@latest

# agmsg runtime (bash+sqlite skills install)
git clone --depth 1 https://github.com/fujibee/agmsg.git /workspace/factory/tools/agmsg
cd /workspace/factory/tools/agmsg && ./install.sh --cmd agmsg
```

## Installed versions / paths

| Component | Version | Binary / path |
|-----------|---------|---------------|
| dsh | 0.2.1-rc.5 | `/home/box/.local/bin/dsh` (npm `@deepseek-ai/dsh`) |
| OpenCode | v2.2.5 | `/home/box/.local/bin/opencode` (npm `@opencode/cli`; also `opencode2`) |
| agmsg (npm bootstrap) | 1.7.0 | `/home/box/.local/bin/agmsg` |
| agmsg (runtime) | git `64723d6` | `~/.agents/skills/agmsg/` |
| sqlite3 | 3.54.1 | `/home/box/.local/bin/sqlite3` |

Verify:

```bash
dsh --version          # 0.2.1-rc.5
dsh headless --help
opencode --version     # opencode v2.2.5
opencode acp --help
agmsg --version
sqlite3 --version
```

Note: legacy npm package `opencode-ai` exists (1.19.5) but current OpenCode README / DSH ACP path use `@opencode/cli` (`opencode acp`).

## agmsg local send/receive test

```bash
export AGMSG_STORAGE_PATH=/tmp/agmsg-p1-test/db
AG=~/.agents/skills/agmsg
bash $AG/scripts/join.sh p1test alice hermes /tmp/agmsg-p1-test/proj-a
bash $AG/scripts/join.sh p1test bob   hermes /tmp/agmsg-p1-test/proj-b
bash $AG/scripts/send.sh p1test alice bob "p1 hello from alice"
bash $AG/scripts/inbox.sh p1test bob
# -> "1 new message(s): ... alice: p1 hello from alice"
bash $AG/scripts/team.sh p1test --delete --force --purge-messages --yes
rm -rf /tmp/agmsg-p1-test
```

Result: **PASS** (send + inbox receive between two hermes identities; cleaned up).

## dsh headless status (no API keys)

```bash
cd /tmp/dsh-probe/ws
env -u DEEPSEEK_API_KEY -u OPENAI_API_KEY -u ANTHROPIC_API_KEY \
  dsh headless --json "reply with exactly: pong"
```

Observed:

- stderr: `dsh: MISSING_CREDENTIAL: llm-deepseek: no API key for provider route "deepseek-official"; ... export DEEPSEEK_API_KEY in the launching environment`
- json final event with empty text; process exit code was **0** despite the credential error (surprise).

Stopped here: no keys available / inventing keys forbidden.

### What is needed to finish a real headless task

Shipped headless profile (from `dsh --profile headless --dump-default-config` / `dsh-base`):

- Default route: **`provider: deepseek-official`**, **`model: deepseek-flash`**
- Credential env (headless disables interactive credential store): **`DEEPSEEK_API_KEY`**
  - Resolution order for headless: launch env → `<cwd>/.env` → `$DSH_HOME/.env` (default home created at `~/.dsh`)
- Optional alt providers via dormant `llm-pi-ai` settings (examples in docs): `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, plus provider-native ambient vars (`AZURE_OPENAI_API_KEY`, `AWS_PROFILE`, …) when configuring pi-ai routes
- Permission-related env seen in composition: `DSH_PERMISSION_MODE` (sandbox/approval)

### README / design-doc model string check

- Top-level repo README (`master`): only shows `npx @deepseek-ai/dsh web` — **does not** name `openai/gpt-6.1-sol` or `deepseek-official/deepseek-flash`
- Shipped default in installed 0.2.1-rc.5: **`deepseek-official` / `deepseek-flash`**
- Some tests / ACP profile docs mention `deepseek-v4-flash`; not the headless agent-default-model

## Design-relevant surprises

1. **sqlite3**: not present; Debian apt mirrors 500’d — installed official sqlite-tools zip to `~/.local/bin`. agmsg hard-requires `sqlite3` CLI.
2. **OpenCode package**: use `@opencode/cli` (has `opencode acp`), not older `opencode-ai`.
3. **DSH ↔ OpenCode / Claude Code**:
   - Not on by default in headless. Optional packages: `@deepseek-ai/dsh-subagent-claude-code` (Agent SDK, pinned runtime, no host `claude` fallback), `@deepseek-ai/dsh-subagent-acp` (spawn any ACP command — OpenCode via `opencode acp`), `@deepseek-ai/dsh-subagent-codex`.
   - Child env: `scrubbedParentEnv` drops ambient names matching `/KEY|PASSWORD|SECRET|TOKEN/i` and ambient `DSH_*`; explicit `env` overlay required to pass keys to children.
4. **AskUserQuestion**: `user-questions` service is mounted; **`tool-ask-user` is NOT** in shipped headless tool list. Prompt text still mentions `ask_user_question` in plan-mode instructions. No dedicated “disable AskUserQuestion” headless flag found; disabling would be a cordis patch removing/disabling the tool/service if added.
5. **Headless exit code**: MISSING_CREDENTIAL still exited 0 in this probe (stderr + json error status). Supervisors should not rely on exit code alone.
6. Latest GitHub tag was `dsh-v0.2.2-alpha.3`; npm installed design-doc target **0.2.1-rc.5**.

## Pass condition vs result

| Check | Status |
|-------|--------|
| Install DSH, OpenCode, agmsg | Done |
| Binaries `--version`/`--help` | Done |
| agmsg send/receive | **PASS** |
| `dsh headless` completes one task | **BLOCKED** — needs `DEEPSEEK_API_KEY` (or configured alternate provider keys) |

## P2 follow-up (2026-11-03)

- Installed into headless profile: `@deepseek-ai/dsh-subagent-claude-code@0.2.1-rc.5` (bundle), `@deepseek-ai/dsh-subagent-acp@0.2.1-rc.5` (plain dep + manual patch rows for OpenCode ACP).
- Config: `~/.dsh/profiles/headless/cordis.patch.yml`
- Runbook: `/workspace/factory/p2-run.md`

## P1 factory-orchestrator (2026-11-03 23:56 JST)

- Plugin: `/workspace/factory/plugin/index.js`
- Patch: `/workspace/factory/config/factory.patch.yml` (file paths to `lib/index.js` / `index.js`)
- Wrapper: `/workspace/factory/bin/factory-step`
- No-key verify: exit 1; stdout JSON `stopReason=error` with Claude Code product failure; stderr `factory: step start/end`; no DeepSeek `MISSING_CREDENTIAL`.
- `CLAUDE_CODE_OAUTH_TOKEN` absent → P2 live smoke skipped.
