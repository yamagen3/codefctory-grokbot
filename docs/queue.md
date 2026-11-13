# factory-queue — intake queue for code-cli runs

`factory-queue` holds requests until the provider is available. `factory-tick`
starts at most one run per tick, so a cron entry keeps the factory turning
while Claude Code is rate-limited.

## Storage

The queue root is `$FACTORY_QUEUE_DIR` (default `local/queue`).

```text
local/queue/
  pending/    waiting entries
  started/    entries handed to factory-run-local
  status.json latest run-next summary
  .lock       held by run-next while it selects and starts an entry
```

Each entry is one JSON file named `<UTC yyyymmddThhmmssZ>-<id>.json` and is
written atomically:

```json
{
  "schema": 1,
  "id": "example",
  "kind": "code-cli",
  "target": "example-target",
  "brief": "what to build",
  "grok_mode": "pending",
  "grok_stub": null,
  "queued_at": "2026-11-13T12:34:56Z"
}
```

With neither Grok flag the entry stores `grok_mode: "pending"`. A queued run
therefore never falls back to `factory-run-local`'s local `stub=pass` default.
`--grok-mode M` stores `M` in `grok_mode`; `--grok-stub S` stores `S` in
`grok_stub`. The flags are mutually exclusive.

## Commands

```bash
factory-queue add <id> --target <name> \
  [--grok-mode M | --grok-stub S] (--brief-file F | -- <brief...>)

factory-queue list [--json]  # pending entries, oldest first
factory-queue count          # number of pending entries
factory-queue remove <id>    # pending entries only
factory-queue run-next       # start the first eligible pending entry
```

`add` validates `<id>` and `--target` against
`^[A-Za-z0-9][A-Za-z0-9._-]*$`; an invalid value exits 1. It refuses an id that
is already in `pending/` or `started/`, or that already has
`<runs dir>/<id>/state.json`. This keeps a later requeue from wiping an existing
work clone.

`remove` deletes a pending entry. It refuses an id that has already moved to
`started/`; started entries are owned by the run and its `state.json`.

## States

- **pending** — waiting for `run-next`. `list` and `count` report only these.
- **started** — `run-next` moved the entry before invoking the run command. A
  run that parks on a provider limit also lives here; `factory-resume` picks it
  up later through its `state.json`.

## run-next

`run-next` takes `flock -n` on `<queue>/.lock`; if another call holds it, it
exits 0. With no pending entry it exits 0 without output.

Before starting anything it runs `factory-provider-state check claude-code`.
If that exits 75, `run-next` prints its line and exits 75, leaving the entry
pending.

Next it runs a profile preflight:

```bash
${FACTORY_QUEUE_PREFLIGHT_CMD:-$FACTORY_ROOT/bin/factory-profile check}
```

The default preflight is skipped when `$FACTORY_ROOT/bin/factory-profile` is
not executable or `$FACTORY_ROOT/profiles` is missing. An explicit
`FACTORY_QUEUE_PREFLIGHT_CMD` always runs. If the preflight exits non-zero,
`run-next` prints `blocked profile-check` on stdout, copies the tool's output
to stderr, leaves every entry pending, and exits 1.

Otherwise it walks the pending entries oldest first and takes the first
eligible one:

- An entry whose `kind` is not `code-cli` is skipped with a warning on stderr.
- Unless `FACTORY_QUEUE_SERIAL_TARGET=0`, an entry is deferred while any
  `<runs dir>/*/state.json` with the same `target` has `exit` null, 2, or 75.
  A deferred entry prints `deferred <id> target-busy=<run-id>` on stdout.
- With no eligible entry, `run-next` exits 0.

The selected entry moves to `started/`, then runs:

```bash
${FACTORY_QUEUE_RUN_CMD:-factory-run-local} <id> <brief>
```

with `FACTORY_TARGET_NAME` and the entry's Grok variable exported. The run's
stdout and stderr are appended to
`${FACTORY_LOG_DIR:-$FACTORY_ROOT/local/logs}/queue-<id>.log`; they are not
written to the caller's stderr. `run-next` prints only
`started <id> exit=<ec>` on stdout and exits 0 even when the run itself exits
non-zero. One call starts one entry.

## status.json

After every `run-next` that takes the queue lock, `<queue>/status.json` is
replaced atomically:

```json
{
  "time": "2026-11-13T12:34:56+00:00",
  "pending": 2,
  "blocked": null,
  "last": {"id": "example", "exit": 0}
}
```

`pending` is the number left in `pending/`. `blocked` is null or
`"profile-check"`. `last` records the most recent start; it is carried over
unchanged when this call started nothing, and is null before the first start.

## Tick integration

After the resume pass, and only when resume did not exit 75, `factory-tick`
runs `${FACTORY_TICK_QUEUE_CMD:-factory-queue run-next}` with the same
`FACTORY_PROVIDER_WAIT`. The queue's stdout is appended to
`tick-resume.log`, and `started ...` lines are recorded in the `started` list
in `tick.json`. A queue exit of 75 sets `provider_limited`; any other queue
failure is logged to stderr and does not abort the tick or skip the inbox pass.
