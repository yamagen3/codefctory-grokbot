# pstack on factory Claude Code

pstack is a skill library. It is not a model, and it does not choose the factory's Claude or OpenCode models.

## What was already true

`bin/factory-pstack-install` (from `factory-setup`) clones `michael-denyer/pstack-claude` at `79b36d9b53a53c78e5ec26bf6ce7dade76686c87` and copies the manifest subset to:

- `~/.claude/skills/<name>` for Claude Code
- `/home/factory-oc/.agents/skills/<name>` for OpenCode, with symlinks under `.config/opencode/skills`

That pin, the manifest, and the security-update policy are unchanged. Re-running the installer deletes and recopies each skill directory, then rewrites `local/pstack-installed-sha`.

## Diagnosis

DSH-installed skills do not inherit into Claude Code.

| Layer | What it actually loads |
|---|---|
| DSH `~/.agents/skills` | agmsg scripts for the factory plugin. The Claude subagent never reads this tree. |
| DSH `subagent-claude-code` | One Agent SDK `query()` per run. Official provider README: it omits `settingSources`, so the SDK's own default applies. It does not copy skill files into the prompt. |
| Agent SDK `settingSources` | Omitted: user + project + local, matching the CLI. `[]` disables filesystem settings. `['user']` is only `~/.claude/` (and not the product repo's `.claude/`). The same comment is in `sdk.d.ts` for 0.3.318 and for the approved 0.3.319 package. |
| Skills once a source loads | Claude Code sees skill *descriptions* and loads a body when the model invokes the Skill tool. A file on disk is not yet an instruction the model has read. |
| Session `cwd` | The product repo (`request.cwd`). Project skills would be `<repo>/.claude/skills`, which factory does not install. |
| Child `HOME` | The provider passes scrubbed parent env plus the factory env overlay (OAuth token, `FACTORY_CC_STEP`, effort). User skills resolve from that process home, not from `cwd`. This cloud checkout cannot see the box user's home. |
| Upstream Claude adapter at the same pin | `plugins/pstack/hooks/hooks.json` runs `hooks/session-start.sh` on SessionStart. For Claude that script prints `hooks/session-start-context.md`, which tells the model to invoke `pstack:poteto-mode`. Copying skill directories does not install that hook. |

`poteto-mode` at this pin is a 28k-character playbook. It tells the agent to use the Agent tool, `AskUserQuestion`, and model routing (`arena`, `swarm`, `interrogate`, `pstack-models.md`). Those are Cursor-shaped operations. Factory CC denies `AskUserQuestion`, pins `claude-opus-5-5` at effort `xhigh`, and does not implement the product.

## Two shapes

**A. Native plugin.** Pass the SDK `plugins` option at `plugins/pstack` so the SessionStart hook runs. That is the upstream "on by default" switch. It also turns every CC step into a poteto-mode router, asks for subagents and other models, and duplicates gate/review. The marketplace installer would not stay on the factory pin. Not used.

**B. Stage bootstrap at the SDK boundary (used).** `plugin/cc-allowlist/pstack-session.js` returns the options the patched `claudeQueryOptions` spreads into `query()`:

- `settingSources: ['user']` so the child loads the installed user skills and does not load a product repo's `.claude` settings or hooks.
- For `FACTORY_CC_STEP=spec` or `gate` only: `skills` is that stage's name list, and `systemPrompt` is `{ type: 'preset', preset: 'claude_code', append }` containing those SKILL.md bodies. The preset keeps Claude Code's own prompt. Other steps get `settingSources` only, so the whole library is not injected.
- Names must be in `config/pstack-skills.manifest`. A missing file, a frontmatter name that differs from the directory, or a body over 16000 characters throws. The CC step fails instead of running without the instructions.

`scripts/apply-cc-allowlist-patch.sh` inserts the import and `...pstackQueryOverlay()` when `factory-setup` rebuilds the provider from its stock file. A second setup run restores stock and applies the same result. It does not add `bypassPermissions` or change `permissionMode`.

## What spec and gate read

| Step | Skills in the prompt | Not in the prompt |
|---|---|---|
| spec | `principle-model-the-domain`, `principle-sequence-verifiable-units`, `principle-prove-it-works`, `technical-writing` | poteto-mode, architect, tdd, how/why, interrogate |
| gate | `principle-prove-it-works`, `principle-test-behavior-not-implementation`, `show-me-your-work` | technical-writing, and every playbook above |

The append tells the model to skip Cursor Task, subagent model routing, `setup-pstack`, and arena/swarm/reflect/interrogate, and to leave IMPL parallelism at `spec/IMPL_STRATEGY.md` (`parallel: N`, 1..4). OpenCode still implements. The task strings in `factory-spec-step` and `factory-gate-claude` are not a second copy of the library.

## Skipped on purpose

- Plugin SessionStart auto-route to poteto-mode.
- `setup-pstack` and any rewrite of model choices. CC remains `claude-opus-5-5` / `xhigh`. OpenCode remains `opencode-go/deepseek-v4.1-flash` with `reasoningEffort=max`.
- arena, swarm, reflect, thermos, GitHub babysit skills (already absent from the manifest).
- Agent-tool fan-out and multi-model gates. Parallelism stays the existing OpenCode IMPL fan-out.
- Treating OpenCode's `.agents/skills` copy as proof that OpenCode applied the text. That path was not re-verified here.

## Box versus this checkout

Editing this repo does not change the shared box. On the box, after this branch is deployed, run `factory-setup` (or `factory-pstack-install` and `scripts/apply-cc-allowlist-patch.sh`) as the same user that launches DSH. `factory-doctor` then checks the stage skill files under `~/.claude/skills`. Set `FACTORY_PSTACK_OVERLAY_LOG` to a path if a live CC run should append one JSON line per query (names, paths, append length, sha256; not the skill text and not credentials). A passing offline test is not that live run.
