# Extensibility design proposal

Status: proposal only. This document describes seams that exist today and a possible
target design. It does not add a provider, change a model, or change runtime behavior.
See [Status](#8-status).

## 1. Current seams

The factory already has useful extension points. They are real seams, but most are
attached to one specific provider or one specific product pipeline.

### `bin/factory-step` — provider adapter boundary

`bin/factory-step` is the executable boundary between the orchestrator and a model
CLI. It takes the task as command-line input, selects `FACTORY_PROVIDER`
(`claude-code` by default), checks the provider-limit state, and runs
`lib/factory_step.py`, which starts one standard CLI process for the step (no DSH
since 2026-11-14). Usage tracking records wall time and tokens around that process.

The result is a JSON document when `--json` is used: `stopReason`, `output`, `text`,
and optional `diagnostic` and `usage`. The runner also writes a
`factory: step end stopReason=… exit=N` line to stderr (`completed` → 0, timeout →
124, anything else → 1). `factory-step` treats a missing `factory: step end` line
as an error and turns a provider limit into exit 75.

Secret scrubbing happens in the runner, per provider:

- Claude Code: `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` are always removed,
  as are all DeepSeek, OpenCode, and factory workspace keys. `factory-step` stashes
  `CLAUDE_CODE_OAUTH_TOKEN` as `FACTORY_CC_OAUTH_TOKEN`; the runner gives the
  `claude` child only `CLAUDE_CODE_OAUTH_TOKEN`. `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`
  is removed: on 2.1.319 it forces permission mode `default` and blocks edits.
- OpenCode: `OPENCODE_GO_KEY` (or `FACTORY_OC_API_KEY`) is required. The key is
  stashed as `FACTORY_OC_API_KEY`, all other provider and GitHub secrets are
  removed, and the step runs in a private workspace. The isolated launcher maps the
  stash to `OPENCODE_API_KEY` only inside the bwrap sandbox.
- Unknown provider: exit 2, no fallback.

The scrub is per provider, so every new provider needs a new branch even though the
adapter shape is otherwise shared.

### `lib/factory_step.py` — one runner function per provider

`run_claude` builds the `claude -p` command line from `config/claude-code.json`
(model, effort, permission mode, setting sources, denied tools) and wires the
PreToolUse/Stop/StopFailure hooks in `lib/cc/hook.mjs` through `--settings`.
`run_opencode` runs `sudo -n bin/opencode-acp-isolated run <task>`, which starts
`opencode run --format json` inside bwrap. A new provider is a new runner function
plus its env scrub.

### Test seams: `FACTORY_STEP_BIN`, `FACTORY_STEP_RUNNER`, `FACTORY_CLAUDE_BIN`

`bin/factory-step` runs `${FACTORY_STEP_RUNNER:-python3 lib/factory_step.py}`, so
tests can replace the runner without a model call; `FACTORY_CLAUDE_BIN` and
`FACTORY_OC_LAUNCHER` replace only the CLI under the real runner.
`bin/factory-impl-step` invokes `${FACTORY_STEP_BIN:-factory-step}`, so tests can
replace the whole step adapter. These keep the role scripts testable offline. They
do not remove the role-specific provider choice inside the scripts.

### `lib/factory_github/client.py` — Backend interface

`Backend` defines the status/label/PR operations:

- `status_set`, `status_get`, `status_required_ok`
- `labels_set_round`, `labels_get_round`
- `pr_create`, `pr_merge`

`LocalBackend` stores statuses, labels, and PR records as JSON under
`local/status`, `local/labels`, and `local/prs`, and mirrors statuses into git
notes. `GitHubBackend` mirrors locally and pushes statuses, labels, PRs, and
merges through the GitHub API. `get_backend()` selects `local` or `github` from
`FACTORY_BACKEND`. The interface is transport-neutral; the required-check list is
not.

## 2. What is hard-coded today

| Area | Current hard-coding | Consequence |
|---|---|---|
| Role → provider | `bin/factory-spec-step` exports `FACTORY_PROVIDER=claude-code`; `bin/factory-impl-step` exports `FACTORY_PROVIDER=opencode`; `bin/factory-gate-claude` exports `FACTORY_PROVIDER=claude-code` | A role's provider is a property of a shell script, not of config. Replacing a provider means editing scripts. |
| Stage order | `bin/factory-run-local` runs SPEC → freeze/tag → (IMPL → GUARD → CI → gate/claude → gate/grok) → MERGE. Guard, CI, and gate failures continue the round; SPEC/IMPL failures exit under `set -e`. The default limit is 3 rounds (`FACTORY_MAX_ROUNDS`). | The sequence, retry policy, and round limit live in one shell loop. A different pipeline cannot be described without another loop. |
| Required checks | `REQUIRED = ("guard", "ci", "gate/claude", "gate/grok")` in `lib/factory_github/client.py`; `factory-merge` calls `status_required_ok` | Every product pipeline must satisfy exactly those four contexts. A screenplay or video pipeline cannot use its own checks without a code change. |
| Protected paths | `spec/`, `tests/acceptance/`, `.github/` in `bin/factory-patch-extract` (removed from the diff and refused by `check`) and in `bin/factory-guard` (diffed against `spec/<id>`); `bin/factory-impl-step` also strips them from the winner | The same three paths are repeated in three places. Another pipeline cannot protect `script/` or `media/` without edits. |
| Acceptance | `bin/factory-ci` runs only `python3 -m unittest discover` for `tests/unit` and `tests/acceptance`, with `PYTHONPATH=src` and `python3.12` preferred over `python3`; `bin/factory-impl-step` scores winners by counting unittest `... ok` lines in `tests/acceptance` | Acceptance is Python-unittest-only. Non-Python products, text checks, and ffprobe checks are invisible to CI and to winner selection. |
| Diff transport | `bin/factory-patch-extract` makes `diff -ruN` from a clean tree and the agent tree. It refuses binary diffs and new symlink modes (`120`), then applies with `git apply` or `patch` fallbacks | Only text changes can travel from an agent to the product repo. Binary artifacts have no supported path. |

Role prompts and write allowlists are also embedded in shell scripts. The stage
behavior is therefore imperative, not declarative.

## 3. Proposed stage model

Every stage, regardless of provider or artifact type, has four phases:

1. **Prepare.** The orchestrator reads the pipeline descriptor, selects the
   provider for the role, creates an isolated copy of the product at the base
   revision, applies the stage's write policy, seeds the provider home and the one
   allowed credential, and composes the stage prompt from the frozen inputs.
2. **Run.** The provider adapter runs the agent in that isolated copy. The agent
   may create, delete, or modify anything inside the copy; none of it is trusted
   yet. Exit code and output JSON are recorded.
3. **Collect.** This is the only phase allowed to change the product repository.
   The orchestrator reads the agent's copy, enforces the write policy, and
   transports accepted artifacts to a clean base: text patches for code and
   scripts, a recipe plus manifest for video. Protected paths, binary policy,
   symlink policy, and size limits are checked here. Accepted artifacts get a
   type, size, and sha256. Rejected artifacts fail the stage.
4. **Check.** The orchestrator runs the stage's checks (command, agent verdict, or
   external verdict), records statuses against the resulting commit, and uses only
   collected artifacts for fan-out selection and retries.

IMPL already follows this shape: an isolated workspace, `factory-patch-extract`
to collect a text patch, protected-path and binary checks, application to a fresh
clone, and acceptance scoring. SPEC and the gates still write or read the real
tree directly, guarded by the Claude Code filesystem allowlist. The proposal is to
normalize all stages onto the same prepare/run/collect/check contract.

A role becomes a description of required inputs and checks, not a vendor. Any
agent that implements the adapter contract can fill any role: Claude Code for
SPEC, OpenCode for IMPL, another approved agent for a rubric gate, and so on.
Fan-out can compare multiple providers for the same role and select by collected
artifact score.

## 4. Provider adapter contract (proposal)

Define one adapter contract for every provider. `bin/factory-step` remains the
reference implementation and stays the stable entry point for tests.

### Inputs

- Stage id and role (`spec`, `impl`, `gate`, or a pipeline-defined role).
- Task prompt and optional previous artifacts (paths plus sha256).
- Working directory: an isolated copy, never the shared factory checkout.
- Write policy: writable paths, read-only paths, and protected paths.
- Provider identity, model selection reference, and timeout.
- Output mode (`json` for orchestration), verdict format when the stage is a gate.
- Environment allowlist (variable names only; the adapter injects at most one
  provider credential).

### Output JSON

Keep today's step payload keys and extend them without breaking readers:

```json
{
  "schema": "factory.step/v1",
  "provider": "opencode",
  "stopReason": "completed",
  "output": [],
  "text": "agent text",
  "artifacts": [
    {"path": "src/example.py", "sha256": "...", "size": 123, "type": "text/x-python"}
  ],
  "usage": {},
  "diagnostic": null
}
```

`stopReason`, `output`, `text`, `diagnostic`, and `usage` keep their current
meaning. `artifacts` is advisory metadata; the collect phase re-hashes everything
it accepts. A provider that cannot produce this shape is not eligible.

### Exit codes

| Code | Meaning |
|---:|---|
| 0 | Ok: step completed and produced a collectable result. Checks are not implied. |
| 1 | Product failure: the agent failed, the output is invalid, collect refused the artifacts, or a check failed. Retryable within the round policy. |
| 2 | Verdict pending: an external or asynchronous check has no verdict yet. The orchestrator stops, records `pending`, and must not merge. |
| 3 | Max rounds reached. This is a pipeline/orchestrator outcome, not a normal adapter result. |
| 75 | Temporary/quota failure. Retry later with backoff; do not count it as a product failure. |
| 124 | Stall/timeout after the configured retry policy (the value `timeout(1)` already returns). |

No other exit codes are part of the contract. Adapter-specific codes are mapped
to one of these before the orchestrator reads them.

### Secret-scrub rule

Exactly one provider credential may cross into an agent process:

- The selected credential enters the adapter under a `FACTORY_*` stash name.
- The parent environment loses every other provider, agent, GitHub, and CI
  token/key/secret variable before the child starts.
- The sandbox launcher builds a clean environment (`clearenv`) and re-injects the
  one selected credential only into that child.
- The credential is passed by environment only. It never appears in argv, files,
  prompts, patches, usage records, status descriptions, or logs. Diagnostics may
  name variables, never values.
- The leak check must prove that the other credentials are absent and that the
  selected one is present. The doctor may check presence by name only.

### Isolation requirement for every new agent

Adding an agent such as OpenAI Codex is a security change, not only a config
entry. Each new agent needs all of the following before it can fill a role:

- **Its own system user.** For example `factory-codex`, distinct from
  `factory-oc` and the human/box user. No shared home, key, or workspace.
- **Its own key.** A separately named credential and environment variable, held
  outside the repository. Other providers' keys must be absent.
- **Its own sudoers and bwrap launcher entry.** A dedicated launcher (analogous to
  `bin/opencode-acp-isolated`) plus a matching `/etc/sudoers.d/` entry. The
  sandbox exposes only the workspace, the agent home, and required read-only
  system paths. It must not mount the host home, the factory checkout, or another
  agent's home, and it strips `.git` from the workspace.
- **Leak-check coverage.** A provider-specific leak check with the same 14-point
  shape as `bin/factory-oc-leak-check`: other keys absent, selected key present,
  only the expected secretish environment variable, host home hidden, factory
  config hidden, `.git` stripped.
- **Doctor coverage.** `bin/factory-doctor` must check the user, binary, launcher,
  sudoers entry, bwrap, key presence (name only), and model/config pin for the new
  agent, and fail rather than silently fall back.
- **A `factory-update` rule in the `needs-approval` class.** Inventory the agent
  package/binary, launcher, sudoers file, and config pin. Every update to them is
  `needs-approval`, never `auto`, in the same class as the Claude Code CLI pin
  and the pstack SHA pin. General OS security/patch updates keep
  their existing auto policy.
- **Owner approval and credentials.** The provider is enabled only after the
  owner approves it and supplies its credential out of band.

The provider registration itself is a runner function in `lib/factory_step.py`
plus an adapter branch; unknown providers fail closed.

## 5. Pipeline descriptor (proposal)

A pipeline is a read-only JSON file: `config/pipeline.<name>.json`. It contains no
secrets, only provider names, model references, commands, and paths.

Required fields:

- `schema` and `name`.
- `stageOrder` and `stages`: stage id, kind (`agent`, `command`, `external`, or
  `orchestrator`), role, provider, read/write policy, collect policy, fan-out, and
  check ids.
- `maxRounds` and the repeat range.
- `protectedPaths`.
- `acceptance`: command(s), environment, and interpreter fallback.
- `requiredChecks`: the status contexts that must all be `success` before merge.
- Optional storage/staging policy for non-text artifacts.

The loader resolves an explicit pipeline name; the current behavior becomes the
`code` descriptor. Unknown providers, check types, or protected-path escapes fail
closed. A descriptor cannot grant a new credential by itself.

The following example reproduces today's code pipeline: the same stage order,
providers, fan-out rules, round limit, protected paths, acceptance commands, and
four required checks.

```json
{
  "schema": "factory.pipeline/v1",
  "name": "code",
  "maxRounds": 3,
  "protectedPaths": ["spec/", "tests/acceptance/", ".github/"],
  "requiredChecks": ["guard", "ci", "gate/claude", "gate/grok"],
  "acceptance": {
    "python": ["python3.12", "python3"],
    "env": {"PYTHONPATH": "src"},
    "commands": [
      "{python} -m unittest discover -s tests/unit -v",
      "{python} -m unittest discover -s tests/acceptance -v"
    ]
  },
  "stageOrder": ["spec", "freeze", "impl", "guard", "ci", "gate-claude", "gate-grok", "merge"],
  "repeat": {"from": "impl", "to": "gate-grok", "maxRounds": 3},
  "stages": [
    {
      "id": "spec",
      "kind": "agent",
      "role": "spec",
      "provider": "claude-code",
      "writes": ["spec/", "tests/acceptance/"],
      "collect": "fs-allowlist"
    },
    {
      "id": "freeze",
      "kind": "orchestrator",
      "actions": [
        "git add -A && git commit -m 'factory({id}): spec freeze'",
        "git tag -f spec/{id}",
        "git push origin factory/{id}",
        "git push origin spec/{id}"
      ]
    },
    {
      "id": "impl",
      "kind": "agent",
      "role": "impl",
      "provider": "opencode",
      "writes": "isolated-copy",
      "collect": "patch-extract",
      "fanOut": {
        "envOverride": "FACTORY_OC_PARALLEL",
        "source": "spec/IMPL_STRATEGY.md",
        "key": "parallel",
        "default": 2,
        "min": 1,
        "max": 4
      },
      "score": "acceptance-pass-count"
    },
    {
      "id": "guard",
      "kind": "command",
      "command": "factory-guard {repo} {id}",
      "check": "guard"
    },
    {
      "id": "ci",
      "kind": "command",
      "command": "factory-ci {repo}",
      "check": "ci"
    },
    {
      "id": "gate-claude",
      "kind": "agent",
      "role": "gate",
      "provider": "claude-code",
      "readOnly": true,
      "verdict": {"pass": "GATE: PASS", "fail": "GATE: FAIL"},
      "check": "gate/claude"
    },
    {
      "id": "gate-grok",
      "kind": "external",
      "provider": "grok",
      "check": "gate/grok",
      "pendingExit": 2
    },
    {
      "id": "merge",
      "kind": "orchestrator",
      "action": "factory-merge {repo} {id}",
      "requires": "requiredChecks"
    }
  ]
}
```

Two notes keep the example honest. SPEC still writes in place under the Claude
Code filesystem allowlist today, recorded here as `collect: "fs-allowlist"`;
moving SPEC to an isolated copy is an implementation step, not a behavior change
required by this proposal. Guard, CI, and gate results remain the four current
contexts, so the existing merge rule is unchanged.

## 6. Non-code pipelines (proposal)

The same stage model, adapter contract, and descriptor format apply. Only the
artifact type, SPEC prompt, collect policy, and checks differ.

### (a) Script/screenplay writing

- **Artifacts are text.** `spec/STORY.md` freezes premise, audience, format,
  target length, and constraints; `spec/OUTLINE.md` freezes beats and scene
  order; `spec/CHARACTERS.md` and `spec/RUBRIC.md` freeze continuity and review
  criteria. IMPL writes `script/*.fountain` or equivalent text.
- **Reuse the patch transport.** `factory-patch-extract` already carries text
  patches, refuses binaries and symlinks, and enforces protected paths. No new
  transport is needed; the protected list becomes the screenplay's own
  (`spec/`, `script/`, `tests/acceptance/`).
- **Different SPEC prompt.** The screenplay SPEC asks for a treatment, scene
  list, character introductions, format, length band, and structural promises
  that acceptance checks can measure. It does not ask for implementation code.
- **Structural acceptance checks.** Command checks verify Fountain syntax, scene
  headings, required beats, character-name consistency, page or word-count
  bounds, formatting constraints, and absence of placeholders. These are
  deterministic and offline.
- **Rubric gate.** An agent verdict check scores explicit criteria, for example
  structure, character voice, dialogue, pacing, continuity, and format, each on a
  fixed scale. It must return the exact `GATE: PASS`/`GATE: FAIL` line plus the
  scores, and pass only when every criterion meets the frozen threshold. The spec
  freezes the rubric so a later round cannot move the goalposts. An external
  editor verdict can remain the final required check.

### (b) Video creation

- **Text recipe from the agent.** The agent produces a script, a shot/edit list
  with timestamps, subtitle text, and a deterministic ffmpeg command/filter file.
  It does not produce video bytes. The recipe is collected through the patch
  transport and is reviewed like code.
- **Deterministic, network-less render.** A command stage runs a pinned ffmpeg
  with no network, read-only inputs from the content-addressed store, a writable
  temporary output, fixed locale/threads, and an allowlisted command form. The
  same recipe and input hashes must produce the same output hash; if the container
  muxer is not bit-reproducible, the gate compares documented media properties
  instead of bytes.
- **Committed manifest, external blobs.** The repository commits a manifest with
  one entry per output: `path`, `sha256`, `size`, and `type` (plus optional
  duration/resolution). Blobs live in a content-addressed store outside git, for
  example `/var/factory/assets/sha256/<digest>`. The manifest contains no blobs;
  the store path is infrastructure state, not repository content.
- **ffprobe gates.** Command checks verify duration within tolerance of the edit
  list, exact resolution and frame rate, expected container/video/audio codecs and
  channel layout, and subtitle timing: cues ordered, inside the duration, not
  overlapping beyond tolerance, and consistent with the approved script. A final
  command recomputes every manifest sha256 and fails if a blob is missing or
  changed. These checks are offline and deterministic.

## 7. Per-pipeline gates

Each pipeline descriptor declares its gates and required checks. Three check types
cover the current and proposed pipelines:

- **Command check.** Run an argv in a prepared workspace with a timeout and an
  env allowlist. Exit 0 is success; any other exit or a timeout is failure. The
  command may print diagnostics, but only the exit code is authoritative unless
  the descriptor names an output parser. Current examples: `factory-guard`,
  `factory-ci`; proposed examples: structural text checks and ffprobe checks.
- **Agent verdict check.** Run a read-only agent stage over the frozen spec and
  collected artifacts. The prompt defines an exact verdict line (for example
  `GATE: PASS` / `GATE: FAIL`) and the rationale or scores required. A pass is
  recorded as `success`; a fail as `failure`; an agent that cannot finish is not a
  pass. Current example: `gate/claude`.
- **External verdict check.** The orchestrator writes a review bundle and waits
  for an out-of-band reviewer or system to record `success` or `failure` through
  a result file or backend status. No verdict means `pending`, the pipeline stops
  with exit 2, and merge is impossible until a success is recorded. Current
  example: `gate/grok`.

A pipeline can mix types. All entries in `requiredChecks` must be `success` for
the same commit SHA before merge. Failed checks return to the next round within
`maxRounds`; pending external checks stop the run without consuming a retry.
Adding a check becomes a descriptor edit plus a status context, not an
orchestrator code change.

## 8. Status

- **This is a proposal only.** No code, config, provider, credential, or model
  setting has been changed by this document. The only repository changes are this
  file, a README link, and a documentation test.
- **No provider or model switch is active.** The current models stay exactly as
  configured: Claude Code uses `claude-opus-5-5` with effort `xhigh`; OpenCode
  uses `opencode-go/deepseek-v4.1-flash` with `reasoningEffort=max`. No OpenAI
  Codex or other provider is added.
- **Adding a provider needs owner approval and credentials.** Isolation, leak
  checks, doctor coverage, and the `factory-update` `needs-approval` rule must be
  in place first. Until then, the existing provider set and behavior remain
  unchanged.
- Implementation would require separate, approved tasks, each with its own
  offline tests. This document alone does not enable any new pipeline.
