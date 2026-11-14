# pstack on factory Claude Code

pstack is a skill library. It is not a model, and it does not choose the factory's Claude or OpenCode models.

## What was already true

`bin/factory-pstack-install` (from `factory-setup`) clones `michael-denyer/pstack-claude` at `79b36d9b53a53c78e5ec26bf6ce7dade76686c87` and copies the manifest subset to:

- `~/.claude/skills/<name>` for Claude Code
- `/home/factory-oc/.agents/skills/<name>` for OpenCode, with symlinks under `.config/opencode/skills`

That pin, the manifest, and the security-update policy are unchanged. Re-running the installer deletes and recopies each skill directory, then rewrites `local/pstack-installed-sha`.

## Diagnosis

Skill files on disk are not yet instructions the model has read.

| Layer | What it actually loads |
|---|---|
| `--setting-sources user` | Only `~/.claude/` settings and skills. A product repo's `.claude/` settings, hooks, and skills are not loaded. |
| Skills once a source loads | Claude Code sees skill *descriptions* and loads a body when the model invokes the Skill tool. |
| Session `cwd` | The product repo. Project skills would be `<repo>/.claude/skills`, which factory does not install. |
| Child `HOME` | User skills resolve from the process home of the user running `factory-step`. |
| Upstream Claude adapter at the same pin | `plugins/pstack/hooks/hooks.json` runs `hooks/session-start.sh` on SessionStart, which tells the model to invoke `pstack:poteto-mode`. Copying skill directories does not install that hook. |

`poteto-mode` at this pin is a 28k-character playbook. It tells the agent to use the Agent tool, `AskUserQuestion`, and model routing (`arena`, `swarm`, `interrogate`, `pstack-models.md`). Those are Cursor-shaped operations. Factory CC denies `AskUserQuestion`, pins `claude-opus-5-5` at effort `xhigh`, and does not implement the product.

## Two shapes

**A. Native plugin.** Install `plugins/pstack` so the SessionStart hook runs. It turns every CC step into a poteto-mode router, asks for subagents and other models, and duplicates gate/review. Not used.

**B. Stage bootstrap on the CLI command line (used).** `lib/cc/pstack-session.js` `stageBootstrap()` is what `lib/factory_step.py` renders before each `claude -p`:

- `--setting-sources user` so the child loads the installed user skills and not a product repo's `.claude`.
- For `FACTORY_CC_STEP=spec` or `gate` only: the stage's SKILL.md bodies are written to a temp file and passed with `--append-system-prompt-file`. That keeps Claude Code's own system prompt. Other steps get no append, so the whole library is not injected.
- Names must be in `config/pstack-skills.manifest`. A missing file, a frontmatter name that differs from the directory, or a body over 16000 characters fails the render, and the CC step fails instead of running without the instructions.

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

Editing this repo does not change the shared box. After deploying, run `factory-setup` (it runs `factory-pstack-install`) as the same user that runs `factory-step`. `factory-doctor` checks the stage skill files under `~/.claude/skills`. Set `FACTORY_PSTACK_OVERLAY_LOG` to a path if a live CC run should append one JSON line per render (names, paths, append length, sha256; not the skill text and not credentials). `node lib/cc/pstack-session.js render <step> <out>` renders the same file by hand.
