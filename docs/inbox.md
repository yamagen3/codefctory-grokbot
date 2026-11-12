# factory-inbox — what the factory is waiting on

`factory-inbox` collects the two things that can stop a local factory run: an
unrecorded Grok gate verdict and a notification that needs a human or supervisor
decision. It is read-only except for the acknowledgement file,
`$FACTORY_NOTIFY_DIR/.acked`.

Directories:

- `FACTORY_GROK_HOOK_DIR` (default `local/grok-hooks`) holds `pending-*.json`,
  `result-*.json`, and `continued-*.json`.
- `FACTORY_NOTIFY_DIR` (default `local/notify`) holds notification files and
  `.acked`.

A missing directory is an empty inbox.

## Items

`pending-<sha>.json` is included only when its `mode` is `pending`.

- **verdict-needed** — there is no `result-<sha>.json` yet. The item has `id`,
  `sha`, `bundle`, `age_sec` (seconds since `created_at`), and an `action` that
  records the verdict:
  `factory-gate-grok record <sha> success|failure "<reason>"`.
- **continue-needed** — a result exists but `continued-<sha>.json` does not. The
  `action` is `factory-continue <sha>`.

A `*-<kind>.txt` notification is included when its `kind` is one of
`max-rounds`, `stall`, `merge-failed`, `continue-stale`, `continue-error`,
`grok-rejected`, `run-aborted`, or `gate-unavailable`, and its basename is not in
`.acked`. Notification items have `kind`, `time`, `message`, and `file` (the
basename). `--all` also includes acknowledged notifications and every other
kind.

Unparsable pending JSON is skipped with a warning on stderr. The command never
dumps the environment or the contents of unrelated files.

## Commands

```bash
factory-inbox list [--json] [--all]  # oldest first; text is tab-separated
factory-inbox count                  # number of attention items
factory-inbox check                  # print the count; exit 10 when non-zero
factory-inbox ack <basename>...       # acknowledge notifications, idempotent
```

`ack` rejects names containing `/` or names that do not exist in the notify
directory. Re-acknowledging a file is a no-op.

## Supervisor loop

1. Run `factory-inbox check`.
2. On exit 10, run `factory-inbox list --json`.
3. Act on each item: record the Grok verdict with `factory-gate-grok record`,
   continue a recorded verdict with `factory-continue`, or re-queue the work that
   produced the notification.
4. Run `factory-inbox ack <basename>...` for the notifications that were handled.

This command is mechanics only. It does not implement a deadline, a timeout, or
an auto-default policy: silence never means success, failure, or permission to
continue.
