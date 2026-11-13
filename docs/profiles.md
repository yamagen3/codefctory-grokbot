# Model profiles

A model profile is one JSON record of the brain model, the maker model, the loop limits, the gates, and the prompt files that are tuned to them. It exists so a configuration can be named and checked without editing eight files by eye.

**The profile is descriptive in this step.** No script reads it to set a model, effort, round limit, or prompt. Behaviour is byte-identical to the configuration before profiles existed. Wiring scripts to consume the profile, and any second profile, are later steps and need an owner decision.

**Adding or switching a profile is an owner decision.** Prompts, effort, gate rules, round limits, and parallelism are tuned together to the brain model. A profile is not a one-line model switch, and a new profile does not by itself change how the factory runs.

## Format

Profiles live in `profiles/<id>.json`. The format is JSON with `schema: 1`, so loading needs only the Python standard library.

- `id`: profile id; it must match `^[a-z0-9][a-z0-9._-]*$`.
- `description`: short human-readable summary.
- `brain`: `provider`, `model`, `effort`, `spec_goal_turns`, `step_timeout_ms`.
- `maker`: `provider`, `model`, `reasoning_effort`, `parallel_default`, `parallel_max`.
- `loop`: `max_rounds`, `stall_timeout_sec`.
- `gates`: `claude` (`required`, `reask_on_no_verdict`), `grok` (`required`).
- `prompts`: `spec`, `gate_claude`, `impl`; each is `{file, anchor}`, where `file` is relative to the factory root and `anchor` is a literal substring of the current prompt in that file.

A profile never holds credentials. Loading rejects unknown top-level keys, wrong types, and any key name matching `key`, `token`, `secret`, or `password` (case-insensitive).

## Selection

`FACTORY_MODEL_PROFILE` selects the profile. It defaults to `default`, which reads `$FACTORY_ROOT/profiles/default.json`. The id is validated before any file is opened, so path-like values such as `../x` are rejected.

## `bin/factory-profile`

The loader is read-only and makes no model calls.

```text
factory-profile id
factory-profile show [--json]
factory-profile get <dotted.key>
factory-profile check
```

`get` exits 1 when the dotted key does not exist. `show` prints flattened dotted keys by default, or the whole document with `--json`.

### `check`

`check` compares the selected profile with the live files and prints one line per mismatch, naming the profile key. It exits 1 when anything drifted and prints `ok` when the profile matches.

| Profile key | File | Expected live text |
|---|---|---|
| `brain.model` | `config/factory.patch.yml` | `model: <brain.model>` |
| `brain.effort` | `config/factory.patch.yml` | `CLAUDE_CODE_EFFORT_LEVEL: '<brain.effort>'` |
| `brain.step_timeout_ms` | `config/factory.patch.yml` | `timeoutMs: <brain.step_timeout_ms>` |
| `maker.model` | `bin/factory-common.sh` | `"model": "<maker.model>"` |
| `maker.reasoning_effort` | `bin/factory-common.sh` | `"reasoningEffort": "<maker.reasoning_effort>"` |
| `brain.spec_goal_turns` | `bin/factory-common.sh` | `FACTORY_CC_GOAL_TURNS:-<brain.spec_goal_turns>` |
| `loop.max_rounds` | `bin/factory-run-local` | `FACTORY_MAX_ROUNDS:-<loop.max_rounds>` |
| `loop.stall_timeout_sec` | `bin/factory-stall-retry` | `FACTORY_STALL_TIMEOUT_SEC:-<loop.stall_timeout_sec>` |
| `maker.parallel_default` | `bin/factory-impl-step` | `PARALLEL=<maker.parallel_default>` |
| `maker.parallel_max` | `bin/factory-impl-step` | `-gt <maker.parallel_max>` |
| `prompts.spec` | `prompts.spec.file` | anchor present |
| `prompts.gate_claude` | `prompts.gate_claude.file` | anchor present |
| `prompts.impl` | `prompts.impl.file` | anchor present |

The gate records are descriptive in this step; `check` does not compare them because the live gate rules are expressed in code paths rather than a configuration file.
