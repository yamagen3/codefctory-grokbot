# P3 log — OpenCode via ACP + isolation

Date: 2026-11-04 (Asia/Tokyo)

## Pass condition

OpenCode, driven by DSH via ACP (`factory` plugin, provider `opencode`), can implement something;
inside OpenCode's environment neither env vars nor readable files expose a Git token or
`CLAUDE_CODE_OAUTH_TOKEN`; OpenCode gets only its DeepSeek-related key; workspace has no `.git`
with push rights.

## Isolation method

- Docker unavailable → unprivileged user `factory-oc` (no sudo) + `bwrap`
- Launcher: `/workspace/factory/bin/opencode-acp-isolated` (root-owned; `sudo -n` from box)
- Sudoers: `/etc/sudoers.d/factory-oc-acp` (env_keep: DEEPSEEK_API_KEY, FACTORY_OC_API_KEY, FACTORY_OC_WORKSPACE)
- bwrap: `--clearenv`, only OC home + workspace writable; `/home/box`, `sand-data` secrets, `~/.dsh`, `/workspace/factory/config` not mounted
- Workspace: `/var/factory/oc-workspaces/*` plain dirs; launcher removes `.git`

## Model

- Configured: `opencode/deepseek-v4.1-flash-free` (OpenCode Go free DeepSeek coding/chat model)
- Box env `DEEPSEEK_API_KEY` holds an `oc_`-prefixed OpenCode key (not a DeepSeek platform `sk-` key)
- Native `deepseek/*` with that value → auth fail; mapping to `OPENCODE_GO_API_KEY` → Go free-limit wall
- Child receives `DEEPSEEK_API_KEY` only (name as requested); do **not** also set `OPENCODE_GO_API_KEY`

## Files changed

- `/workspace/factory/bin/factory-step` — provider `opencode`; stash `FACTORY_OC_API_KEY`; strip `DEEPSEEK_API_KEY` from DSH parent
- `/workspace/factory/bin/opencode-acp-isolated` — sudo→factory-oc→bwrap→`opencode acp`
- `/workspace/factory/config/factory.patch.yml` — ACP provider + env overlay
- `/workspace/factory/plugin/index.js` — unchanged (already provider-agnostic)
- `/home/factory-oc/.config/opencode/opencode.json` — model + `permission: {"*":"allow"}`
- `/etc/sudoers.d/factory-oc-acp`

## Test A (implement)

Command:
`FACTORY_PROVIDER=opencode FACTORY_OC_WORKSPACE=/var/factory/oc-workspaces/p3-acp-final factory-step --json 'Write add.py: def add(a, b): return a + b'`

Result: `stopReason=completed`, exit 0; `add.py` created; `add(2,3)==5` asserted.

## Test B (leak check)

Same bwrap path as OpenCode child: env names + path readability.

- Absent: `CLAUDE_CODE_OAUTH_TOKEN`, `GITHUB_TOKEN`, `GH_TOKEN`, git askpass, keyring flag, etc.
- Present (only OpenCode key): `DEEPSEEK_API_KEY`
- Hidden/unmounted: `/home/box`, `box-secrets.json`, `host-secrets.json`, `~/.dsh`, factory config
- No `.git` in workspace

## Parent dummy model

`factory-step` unsets `DEEPSEEK_API_KEY` before `dsh` for provider=opencode (stashes as `FACTORY_OC_API_KEY`).
Dummy parent remains `deepseek-official/deepseek-flash` and is not invoked (startActivation only).

## Residual risks

- OpenCode free-tier rate/limit (`provider.free-limit`) can fail ACP mid-prompt; paid Go DeepSeek ids were `Model unavailable` on this key
- `oc_` key is not a valid DeepSeek platform key; native `deepseek/*` unusable without a real `sk-` key
- bwrap without user namespaces for `--uid` (run as factory-oc first)
- ACP `permission: allow` + OpenCode config `*` allow — broad tool allowlist inside sandbox only
- SUDO path and root-owned launcher are trusted computing base

## Follow-up (same session)

- ACP Test A reconfirmed: `stopReason=completed` for `add.py` via `factory-step` provider=opencode.
- Local dry-run `v0-csv2md-3`: CC spec + acceptance → OpenCode impl (retry) → tests 23 ok / 1 skipped → GATE: PASS.
- CC permissionMode changed to `bypassPermissions` for unattended writes (was `dontAsk`).


## Paid OpenCode Go reconfiguration (2026-11-04 Asia/Tokyo)

### What was wrong before
1. Used provider/model `opencode/deepseek-v4.1-flash-free` (free OpenCode Models path), not paid Go.
2. Tried `OPENCODE_GO_API_KEY` / raw `DEEPSEEK_API_KEY` as the Go credential env; OpenCode CLI 2.2.5 registers Go via **`OPENCODE_API_KEY`** (`auth list` → "OpenCode Go … environment").
3. Tried `opencode/deepseek-v4.1-flash` (wrong provider prefix) → "Model unavailable". Correct: **`opencode-go/deepseek-v4.1-flash`**.
4. Misread free-tier `provider.free-limit` on free models as proof the key was free-only.

### Correct paid route (configured now)
- Provider: `opencode-go`
- Model: `opencode-go/deepseek-v4.1-flash` (also available: `opencode-go/deepseek-v4-pro`, glm/kimi/… — listed under factory-oc)
- Env in isolated child: `OPENCODE_API_KEY` only (mapped from box `DEEPSEEK_API_KEY` / `FACTORY_OC_API_KEY`)
- Auth file: imported into factory-oc store (`opencode auth import`, integrationID `opencode-go`, value.type=key); home bound only into bwrap; mode 700/600
- Evidence key is Go subscription: authenticated `GET /zen/go/v1/usage` → rolling/weekly/monthly status ok, percent 0; `opencode models` as factory-oc lists `opencode-go/deepseek-v4.1-flash` etc.

### Test A (factory-step, provider=opencode)
- Result: **FAIL** — `stopReason=error`, diagnostic ACP transport; direct bwrap `opencode run --model opencode-go/deepseek-v4.1-flash` → **`This API key can't call models`**
- Config/isolation path is correct; **server rejects this API key for inference** despite usage/models visibility. Needs user to rotate/re-issue Go key in OpenCode Console (and Privacy Global for DeepSeek if still blocked after rotation).

## Re-issued Go key attempt (2026-11-04 ~07:42 Asia/Tokyo)

- Logged out old factory-oc Go cred; imported fresh `factory-oc` credential from current `DEEPSEEK_API_KEY`.
- Box-secrets card `DEEPSEEK_API_KEY` fingerprint **unchanged** vs prior session (same sha8) — re-issue may not have reached this box.
- Direct: `OPENCODE_API_KEY` + `opencode-go/deepseek-v4.1-flash` → `This API key can't call models`.
- Alternate once: `opencode-go/glm-5.3-flash` → same error → **key-wide**, not DeepSeek-only.
- factory-step Test A → ACP transport error; no add.py.
- Usage API still ok / 0%. Test B not re-run (Test A failed).


## OPENCODE_GO_KEY switch (2026-11-04 07:54 JST)

### Fingerprints (sha8 only)
- `OPENCODE_GO_KEY` present; sha8 `92b17314`
- `DEEPSEEK_API_KEY` still on box; sha8 `cdc42ce4` (**different** — old/read-only key)
- factory-oc auth after re-import: sha8 `92b17314` (matches Go)

### Wiring changes
- `factory-step` opencode: require/stash `OPENCODE_GO_KEY` → `FACTORY_OC_API_KEY`; unset `OPENCODE_GO_KEY`, `DEEPSEEK_API_KEY`, `OPENCODE_API_KEY`, … from DSH parent
- `opencode-acp-isolated`: inject child `OPENCODE_API_KEY` only (from stash)
- `factory.patch.yml` ACP overlay: pass `FACTORY_OC_API_KEY` + `FACTORY_OC_WORKSPACE` (no `DEEPSEEK_API_KEY`)
- sudoers env_keep: `FACTORY_OC_API_KEY FACTORY_OC_WORKSPACE OPENCODE_GO_KEY`
- **`DEEPSEEK_API_KEY` unused** for OpenCode path

### Direct model probes
- `opencode-go/deepseek-v4.1-flash` → `This Go model requires Global regions. Select Global in your workspace's Privacy settings`
- `opencode-go/glm-5.3-flash` → **PONG** (key can call models)

### Test A
- `FACTORY_PROVIDER=opencode factory-step` + configured `opencode-go/deepseek-v4.1-flash` → `stopReason=error` ACP transport; no `add.py`
- Root cause: Privacy Global not enabled (not key permissions). ACP initialize via launcher OK.
- Test B and `factory-local-dry-run` **not run** (gated on Test A pass).

### User action needed
Enable **Settings → Privacy → Regions → Global** in OpenCode Console for the Go workspace, then re-run Test A / B / dry-run.


## Narrower OPENCODE_GO_KEY re-issue (2026-11-04 08:27 JST)

### Fingerprints (sha8 only)
- New `OPENCODE_GO_KEY` sha8 `ce57ee41` (≠ retired `92b17314`)
- factory-oc auth: logged out old; imported new; stored sha8 `ce57ee41`

### Probes (factory-oc, `OPENCODE_API_KEY` from GO key)
- `opencode-go/glm-5.3-flash` → **PONG** (exit 0) — key can call models
- `opencode-go/deepseek-v4.1-flash` → **FAIL** — `This Go model requires Global regions. Select Global in your workspace's Privacy settings to use it.`

### Tests
- Test A / Test B / `factory-local-dry-run` **not run** (DeepSeek required; model not switched without user decision).


## Global privacy + paid Go verification (2026-11-04 08:46 JST)

### Probe
- `opencode-go/deepseek-v4.1-flash` → **PONG** (exit 0) after user enabled Privacy → Regions → Global.

### Test A
- `FACTORY_PROVIDER=opencode FACTORY_OC_WORKSPACE=/var/factory/oc-workspaces/p3-test-a-global factory-step --json 'Write add.py: def add(a, b): return a + b'`
- Result: `stopReason=completed` exit 0; `add.py` created; `add(2,3)==5`.

### Test B (leak check, same bwrap isolation as child)
- 14/14 PASS: only `OPENCODE_API_KEY` among secretish env (sha8 `ce57ee41`); absent CC/GH/git askpass/DEEPSEEK/OPENCODE_GO_KEY; `/home/box`, box-secrets, `.dsh`, factory config, `/workspace` hidden; `.git` stripped from workspace.

### factory-local-dry-run
- id=`v0-csv2md-go-20261104-084223` exit 0 (~3.5 min)
- SPEC (CC) completed → IMPL (OpenCode isolated DeepSeek) completed → unit 1 ok + acceptance 18 ok → GATE: PASS (local, no status post)

### Closed blockers
- Key permissions / retired all-permission key / Privacy Global / free-limit misdiagnosis — resolved.
- `DEEPSEEK_API_KEY` unused for OpenCode (optional delete).
