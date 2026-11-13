# factory-queue — intake queue for code-cli runs

`factory-queue` holds requests until the provider is available. `factory-tick`
starts at most one run per tick, so a cron entry keeps the factory turning
while Claude Code is rate-limited.

## Storage

The queue root is `$FACTORY_QUEUE_DIR` (default `local/queue`).

```text
local/queue/
  pending/   waiting entries
  started/   entries handed to factory-run-local
  .lock      held by run-next while it selects and starts an entry
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
factory-queue run-next       # start the oldest pending entry, if any
```

`add` refuses an id that is already in `pending/` or `started/`, or that already
has `<runs dir>/<id>/state.json`. This keeps a later requeue from wiping an
existing work clone.

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

Otherwise it moves the oldest entry to `started/`, then runs:

```bash
${FACTORY_QUEUE_RUN_CMD:-factory-run-local} <id> <brief>
```

with `FACTORY_TARGET_NAME` and the entry's Grok variable exported. It prints
`started <id> exit=<ec>` and exits 0 even when the run itself exits non-zero.
One call starts one entry.

## Tick integration

After the resume pass, and only when resume did not exit 75, `factory-tick`
runs `${FACTORY_TICK_QUEUE_CMD:-factory-queue run-next}` with the same
`FACTORY_PROVIDER_WAIT`. The queue's stdout is appended to
`tick-resume.log`, and `started ...` lines are recorded in the `started` list
in `tick.json`. A queue exit of 75 sets `provider_limited`; any other queue
failure is logged to stderr and does not abort the tick or skip the inbox pass.
