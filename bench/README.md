# Benchmark skeleton

`bin/factory-bench` is an offline validator and scorer for a small set of factory
tasks. It reads JSON files only: it never starts a factory run, invokes a model,
or uses the network. Results are recorded separately, so a score can be repeated
without spending tokens.

## Layout

```
bench/
  README.md
  tasks/<task-id>/task.json
bin/factory-bench
```

Recorded results live outside the task set, one file per profile and task:

```
<results>/<profile-id>/<task-id>.json
```

The seed set contains two stdlib CLI tasks: `csv-column-sum` and `ini-lint`.

## Task format

Each `bench/tasks/<task-id>/task.json` uses schema `1`:

```json
{
  "schema": 1,
  "id": "csv-column-sum",
  "title": "CSV column summer",
  "kind": "code-cli",
  "brief": "Build a Python 3 stdlib command-line tool ...",
  "checks": [
    {"name": "sums-column", "required": true}
  ],
  "expect": {"status": "merged", "max_rounds": 3}
}
```

- `id` must match the task directory name.
- `kind` is `code-cli` for the seed tasks. The field leaves room for other
  factories later.
- `brief` is the text handed to `factory-run-local`.
- `checks` names the hidden checks. A check with `required: true` must be true
  for the task to pass.
- `expect.status` and `expect.max_rounds` define the expected outcome.

Validate every task with:

```
bin/factory-bench validate [--tasks DIR]
```

The default task directory is `bench/tasks`. Validation prints one line per
problem and exits 1 when any task is invalid.

## Recorded result format

```json
{
  "task": "csv-column-sum",
  "profile": "cc-sonnet",
  "source": "recorded",
  "status": "merged",
  "rounds": 1,
  "gate_claude": ["pass"],
  "grok": "pass",
  "checks": {"sums-column": true},
  "wall_ms": 184000,
  "cost": {"cc_usd": 0.42, "oc_tokens": 18320}
}
```

- `task` and `profile` must match the file's task and profile directory.
- `source` is `recorded` or `stub`.
- `status` is `merged`, `max-rounds`, `aborted`, or `parked`.
- `rounds` is the number of implementation rounds.
- `gate_claude` has one `pass` or `fail` entry per round.
- `grok` is `pass`, `fail`, or `null`.
- `checks` maps hidden-check names to `true` or `false`.
- `wall_ms` is a non-negative number.
- `cost.cc_usd` and `cost.oc_tokens` are non-negative values or `null` when the
  cost is unknown.

Score one profile with:

```
bin/factory-bench score <results-dir> --profile <id> [--tasks DIR] [--json] [--min-pass X]
```

`--json` prints the aggregate report and per-task rows. `--min-pass` defaults to
`1.0`.

## Scoring rules

A task passes when all three conditions hold:

1. its result `status` equals `expect.status`;
2. every required check is `true`;
3. `rounds` is less than or equal to `expect.max_rounds`.

A `parked` result is reported as `skipped` and removed from the pass-rate
denominator: a provider outage is not a quality signal. A task with no result
file counts as failed, not skipped.

The report aggregates:

- `pass_rate`: passed tasks divided by evaluated tasks (all tasks except
  skipped ones).
- `first_round_pass_rate`: passed tasks with `rounds <= 1` divided by evaluated
  tasks.
- `mean_rounds`: mean rounds over evaluated tasks that have a result file.
- `gate_false_pass`: evaluated tasks whose last `gate_claude` entry is `pass`
  while at least one required check is false.
- `skipped`: number of parked results.
- `wall_ms` and `cost`: totals over result files that are present, including
  parked results, because their time and spend are real. A cost field is `null`
  when every result leaves it null.

Exit codes:

- `0`: validation succeeded, or `pass_rate >= --min-pass`.
- `1`: validation found problems, or the score is below the minimum.
- `2`: malformed arguments or result files, or an invalid task set passed to
  `score` (validation itself reports task problems with exit 1).

Running the task set against paid models and choosing a profile from these
scores are out of scope for this skeleton. Both are owner decisions; this tool
only validates tasks and scores results that already exist.
