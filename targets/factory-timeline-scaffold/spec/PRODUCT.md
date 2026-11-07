# factory-timeline — Product Brief (seed; SPEC step rewrites)

Log-aggregation tool for the code factory itself. Dashboard showing which agent
did what, with a timelapse-style GUI.

## Constraints (decided)

- Python 3.12+, **stdlib only** (no third-party deps; same stance as csv2md).
- CLI plus a generated **single self-contained static HTML** file (inline CSS/JS,
  no CDN, no network) openable offline.
- Product repo must NOT depend on `/workspace/factory` code.
- Deterministic output for tests; tolerate malformed log lines (skip + warn stderr).

## CLI (v1)

```
factory-timeline events  [STATE_DIR]   # JSON lines of normalized events
factory-timeline summary [STATE_DIR]   # Markdown table: per-agent counts/durations
factory-timeline html    [STATE_DIR] [-o OUT.html]  # offline dashboard
```

`STATE_DIR` defaults to `.` or a documented default; typical input is a factory
`local/` tree containing `logs/agmsg-progress.log`, `status/*.json`,
`labels/*.json`, `notify/`, `grok-hooks/` bundles/results.

## Event schema

Each event: `{ts, agent, step, action, status, target, sha, round, detail}`
where `agent` ∈ `claude-code | opencode | grok | factory | guard | ci | …`.

## HTML dashboard

- Per-agent swimlanes on a time axis
- Play/pause timelapse slider revealing events over time
- Filters by agent / run id

## Out of scope (v1)

- Live tailing / network fetch
- Writing back into factory state
- Non-factory log formats
