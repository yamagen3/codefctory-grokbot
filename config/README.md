# Factory config

- `claude-code.json` — the Claude Code CLI pin used by `lib/factory_step.py` and checked by `factory-doctor`: npm version, model, effort, permission mode, setting sources, denied tools, default step timeout. Changing it goes through `factory-update` (needs approval).
- `pstack-skills.manifest` / `pstack-sha` — pinned pstack subset.
- `profiles/` — pipeline profiles (`docs/profiles.md`).
