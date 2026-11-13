#!/usr/bin/env bash
# factory-bench: validate tasks, collect stub runs, and score stub results offline.
# No model, network, dsh, claude, opencode, or gh calls.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BENCH="$ROOT/bin/factory-bench"
TASKS="$ROOT/bench/tasks"
T="$(mktemp -d /tmp/factory-bench-XXXXXX)"
trap 'rm -rf "$T"' EXIT

fail() { echo "test_factory_bench: FAIL $*" >&2; exit 1; }

run() {
  set +e
  "$@" >"$T/out" 2>"$T/err"
  RC=$?
  set -e
}

score() {
  local profile="$1"
  shift
  SCORE_OUT="$T/score-$profile.json"
  SCORE_ERR="$T/score-$profile.err"
  set +e
  "$BENCH" score "$T/results" --profile "$profile" --json "$@" \
    >"$SCORE_OUT" 2>"$SCORE_ERR"
  SCORE_RC=$?
  set -e
}

json_get() {
  python3 - "$SCORE_OUT" "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
for part in sys.argv[2].split("."):
    value = value[part]
print(value if isinstance(value, str) else json.dumps(value))
PY
}

echo "=== (a) validate the shipped task set ==="
run "$BENCH" validate
[[ "$RC" -eq 0 ]] || fail "(a) validate exit $RC: $(cat "$T/err")"
grep -q "2 task" "$T/out" || fail "(a) validate did not report two tasks: $(cat "$T/out")"

echo "=== (b) a task without brief is invalid ==="
cp -R "$TASKS" "$T/tasks-brief"
python3 - "$T/tasks-brief" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
path = sorted(root.glob("*/task.json"))[0]
doc = json.loads(path.read_text(encoding="utf-8"))
del doc["brief"]
path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
run "$BENCH" validate --tasks "$T/tasks-brief"
[[ "$RC" -eq 1 ]] || fail "(b) validate exit $RC, want 1"
grep -q "brief" "$T/err" || fail "(b) missing brief was not reported: $(cat "$T/err")"
[[ "$(grep -c . "$T/err")" -eq 1 ]] || fail "(b) want one problem line: $(cat "$T/err")"

python3 - "$TASKS" "$T/results" <<'PY'
import json
import sys
from pathlib import Path

tasks_dir = Path(sys.argv[1])
results_root = Path(sys.argv[2])
tasks = [json.loads(path.read_text(encoding="utf-8"))
         for path in sorted(tasks_dir.glob("*/task.json"))]


def result(task, profile, *, fail_required=False, parked=False, rounds=1,
           gate=("pass",), wall_ms=100, cc_usd=0.01, oc_tokens=1000):
    checks = {check["name"]: True for check in task["checks"]}
    if fail_required:
        for check in task["checks"]:
            if check["required"]:
                checks[check["name"]] = False
                break
    return {
        "task": task["id"],
        "profile": profile,
        "source": "stub",
        "status": "parked" if parked else task["expect"]["status"],
        "rounds": rounds,
        "gate_claude": list(gate),
        "grok": None if parked else "pass",
        "checks": checks,
        "wall_ms": wall_ms,
        "cost": {"cc_usd": cc_usd, "oc_tokens": oc_tokens},
    }


def write(profile, task, **overrides):
    directory = results_root / profile
    directory.mkdir(parents=True, exist_ok=True)
    doc = result(task, profile, **overrides)
    (directory / f"{task['id']}.json").write_text(
        json.dumps(doc, indent=2) + "\n", encoding="utf-8"
    )


for task in tasks:
    write("stub-pass", task)

write("stub-gate", tasks[0], fail_required=True, rounds=2,
      gate=("fail", "pass"), wall_ms=200)
write("stub-gate", tasks[1])

write("stub-parked", tasks[0], parked=True)
write("stub-parked", tasks[1])

write("stub-missing", tasks[1])

malformed = results_root / "stub-malformed"
malformed.mkdir(parents=True, exist_ok=True)
(malformed / f"{tasks[0]['id']}.json").write_text("{not json\n", encoding="utf-8")
PY

echo "=== (c) two passing stub results ==="
score stub-pass
[[ "$SCORE_RC" -eq 0 ]] || fail "(c) score exit $SCORE_RC, want 0: $(cat "$SCORE_ERR")"
[[ "$(json_get pass_rate)" == "1.0" ]] || fail "(c) pass_rate $(json_get pass_rate), want 1.0"
[[ "$(json_get evaluated)" == "2" ]] || fail "(c) evaluated $(json_get evaluated), want 2"
[[ "$(json_get skipped)" == "0" ]] || fail "(c) skipped $(json_get skipped), want 0"

echo "=== (d) gate pass with a false required check ==="
score stub-gate
[[ "$SCORE_RC" -eq 1 ]] || fail "(d) score exit $SCORE_RC, want 1"
[[ "$(json_get gate_false_pass)" == "1" ]] || fail "(d) gate_false_pass $(json_get gate_false_pass), want 1"
[[ "$(json_get pass_rate)" == "0.5" ]] || fail "(d) pass_rate $(json_get pass_rate), want 0.5"

echo "=== (e) a parked result is skipped, not counted in the denominator ==="
score stub-parked
[[ "$SCORE_RC" -eq 0 ]] || fail "(e) score exit $SCORE_RC, want 0: $(cat "$SCORE_ERR")"
[[ "$(json_get skipped)" == "1" ]] || fail "(e) skipped $(json_get skipped), want 1"
[[ "$(json_get pass_rate)" == "1.0" ]] || fail "(e) pass_rate $(json_get pass_rate), want 1.0"
[[ "$(json_get evaluated)" == "1" ]] || fail "(e) evaluated $(json_get evaluated), want 1"

echo "=== (f) a missing result file counts as failed ==="
score stub-missing
[[ "$SCORE_RC" -eq 1 ]] || fail "(f) score exit $SCORE_RC, want 1"
[[ "$(json_get pass_rate)" == "0.5" ]] || fail "(f) pass_rate $(json_get pass_rate), want 0.5"
[[ "$(json_get failed)" == "1" ]] || fail "(f) failed $(json_get failed), want 1"

echo "=== (g) --min-pass 0.5 accepts one of two ==="
score stub-missing --min-pass 0.5
[[ "$SCORE_RC" -eq 0 ]] || fail "(g) score exit $SCORE_RC, want 0: $(cat "$SCORE_ERR")"
[[ "$(json_get pass_rate)" == "0.5" ]] || fail "(g) pass_rate $(json_get pass_rate), want 0.5"
[[ "$(json_get min_pass)" == "0.5" ]] || fail "(g) min_pass $(json_get min_pass), want 0.5"

echo "=== (h) malformed result JSON exits 2 ==="
score stub-malformed
[[ "$SCORE_RC" -eq 2 ]] || fail "(h) score exit $SCORE_RC, want 2"
grep -qi "invalid JSON" "$SCORE_ERR" || fail "(h) malformed JSON not reported: $(cat "$SCORE_ERR")"

TASK_ID=$(python3 -c 'import json, pathlib, sys
print(json.loads(sorted(pathlib.Path(sys.argv[1]).glob("*/task.json"))[0].read_text())["id"])' "$TASKS")

COLLECT="$T/collect"
RUNS="$COLLECT/runs"
USAGE="$COLLECT/usage"
RESULTS="$T/results"
mkdir -p "$RUNS" "$USAGE/2026-01-01" "$USAGE/2026-01-02"

python3 - "$RUNS" "$USAGE" <<'PY'
import json
import sys
from pathlib import Path

runs = Path(sys.argv[1])
usage = Path(sys.argv[2])


def state(run_id, **overrides):
    directory = runs / run_id
    directory.mkdir(parents=True, exist_ok=True)
    doc = {
        "id": run_id,
        "target": "bench",
        "stage": "merge",
        "round": 1,
        "sha": "abc",
        "exit": 0,
        "grok_mode": None,
        "grok_stub": None,
        "work": None,
        "max_rounds": 3,
        "updated_at": "2026-01-01T00:00:00+00:00",
    }
    doc.update(overrides)
    (directory / "state.json").write_text(
        json.dumps(doc, sort_keys=True) + "\n", encoding="utf-8"
    )


def feedback(run_id, round_number, stage):
    directory = runs / run_id
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"feedback-r{round_number}.md").write_text(
        f"# Round {round_number} failed at {stage}\n"
        "summary: stub\n",
        encoding="utf-8",
    )


def append(kind, day, records):
    directory = usage / day
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / f"{kind}.jsonl").open("a", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, separators=(",", ":")) + "\n")


state("run-merged", round=2, profile="bench-profile")
feedback("run-merged", 1, "gate-claude")
append("steps", "2026-01-01", [
    {"run_id": "run-merged", "provider": "claude-code", "step": "spec",
     "cost_usd_estimate": 0.25, "total_tokens": 7},
    {"run_id": "run-merged", "provider": "opencode", "step": "impl",
     "total_tokens": 1000},
    {"run_id": "other-run", "provider": "claude-code", "step": "spec",
     "cost_usd_estimate": 9.0},
])
append("steps", "2026-01-02", [
    {"run_id": "run-merged", "provider": "claude-code",
     "step": "gate-claude", "cost_usd_estimate": 0.5},
    {"run_id": "run-merged", "provider": "opencode", "step": "impl",
     "total_tokens": 500},
])
append("runs", "2026-01-01", [
    {"run_id": "run-merged", "wall_ms": 1000},
    {"run_id": "other-run", "wall_ms": 9999},
])
append("runs", "2026-01-02", [{"run_id": "run-merged", "wall_ms": 2500}])

state("run-max", profile="bench-max", exit=3, stage="ci")
feedback("run-max", 1, "ci")

state("run-parked", profile="bench-parked", exit=75, stage="gate-claude")

state("run-unfinished", profile="bench-unfinished", exit=2, stage="gate-grok")
feedback("run-unfinished", 1, "gate-grok")

state("run-noprofile", stage="merge")

state("run-checks", profile="bench-checks")

state("run-nocost", profile="bench-nocost")
append("steps", "2026-01-02", [
    {"run_id": "run-nocost", "provider": "claude-code", "step": "spec"},
    {"run_id": "run-nocost", "provider": "opencode", "step": "impl"},
])
PY

echo "=== collect (a) merged run keeps gate history and sums usage ==="
run "$BENCH" collect run-merged --task "$TASK_ID" --out "$RESULTS" \
  --runs "$RUNS" --usage "$USAGE"
[[ "$RC" -eq 0 ]] || fail "collect (a) exit $RC: $(cat "$T/err")"
python3 - "$RESULTS/bench-profile/$TASK_ID.json" "$TASK_ID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = json.load(handle)
assert doc["task"] == sys.argv[2], doc
assert doc["profile"] == "bench-profile", doc
assert doc["source"] == "recorded", doc
assert doc["status"] == "merged", doc
assert doc["rounds"] == 2, doc
assert doc["gate_claude"] == ["fail", "pass"], doc
assert doc["grok"] == "pass", doc
assert doc["checks"] == {}, doc
assert doc["wall_ms"] == 3500, doc
assert doc["cost"] == {"cc_usd": 0.75, "oc_tokens": 1500}, doc
print("collect (a) result ok")
PY

echo "=== collect (b) max-rounds with a ci failure has no gate entry ==="
run "$BENCH" collect run-max --task "$TASK_ID" --out "$RESULTS" \
  --runs "$RUNS" --usage "$USAGE" --profile bench-max
[[ "$RC" -eq 0 ]] || fail "collect (b) exit $RC: $(cat "$T/err")"
python3 - "$RESULTS/bench-max/$TASK_ID.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = json.load(handle)
assert doc["status"] == "max-rounds", doc
assert doc["rounds"] == 1, doc
assert doc["gate_claude"] == [], doc
assert doc["grok"] is None, doc
print("collect (b) result ok")
PY

echo "=== collect (c) parked run is skipped by score ==="
run "$BENCH" collect run-parked --task "$TASK_ID" --out "$RESULTS" \
  --runs "$RUNS" --usage "$USAGE"
[[ "$RC" -eq 0 ]] || fail "collect (c) exit $RC: $(cat "$T/err")"
score bench-parked --min-pass 0
[[ "$SCORE_RC" -eq 0 ]] || fail "collect (c) score exit $SCORE_RC: $(cat "$SCORE_ERR")"
[[ "$(json_get skipped)" == "1" ]] || fail "collect (c) skipped $(json_get skipped), want 1"
python3 - "$SCORE_OUT" "$TASK_ID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
row = next(item for item in report["tasks"] if item["task"] == sys.argv[2])
assert row["outcome"] == "skipped", row
print("collect (c) skipped ok")
PY

echo "=== collect (d) exit 2 is not finished ==="
run "$BENCH" collect run-unfinished --task "$TASK_ID" --out "$RESULTS" \
  --runs "$RUNS" --usage "$USAGE"
[[ "$RC" -eq 1 ]] || fail "collect (d) exit $RC, want 1"
grep -q "run not finished" "$T/err" || fail "collect (d): $(cat "$T/err")"
[[ ! -e "$RESULTS/bench-unfinished/$TASK_ID.json" ]] \
  || fail "collect (d) wrote a result for an unfinished run"

echo "=== collect (e) no profile exits 2 ==="
run "$BENCH" collect run-noprofile --task "$TASK_ID" --out "$RESULTS" \
  --runs "$RUNS" --usage "$USAGE"
[[ "$RC" -eq 2 ]] || fail "collect (e) exit $RC, want 2"
grep -qi "profile" "$T/err" || fail "collect (e): $(cat "$T/err")"

echo "=== collect (f) --checks are copied and score the task ==="
python3 - "$TASKS" "$T/checks.json" "$TASK_ID" <<'PY'
import json
import sys
from pathlib import Path

tasks = Path(sys.argv[1])
task = json.loads((tasks / sys.argv[3] / "task.json").read_text(encoding="utf-8"))
checks = {check["name"]: True for check in task["checks"]}
Path(sys.argv[2]).write_text(json.dumps(checks, indent=2) + "\n", encoding="utf-8")
PY
run "$BENCH" collect run-checks --task "$TASK_ID" --out "$RESULTS" \
  --runs "$RUNS" --usage "$USAGE" --checks "$T/checks.json"
[[ "$RC" -eq 0 ]] || fail "collect (f) exit $RC: $(cat "$T/err")"
python3 - "$RESULTS/bench-checks/$TASK_ID.json" "$T/checks.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    checks = json.load(handle)
assert doc["checks"] == checks, doc
print("collect (f) checks ok")
PY
rm -rf "$T/one-task"
mkdir -p "$T/one-task"
cp -R "$TASKS/$TASK_ID" "$T/one-task/"
score bench-checks --tasks "$T/one-task"
[[ "$SCORE_RC" -eq 0 ]] || fail "collect (f) score exit $SCORE_RC: $(cat "$SCORE_ERR")"
python3 - "$SCORE_OUT" "$TASK_ID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
row = next(item for item in report["tasks"] if item["task"] == sys.argv[2])
assert row["outcome"] == "pass", row
assert row["failed_checks"] == [], row
print("collect (f) score ok")
PY

echo "=== collect (g) an existing result needs --force ==="
run "$BENCH" collect run-checks --task "$TASK_ID" --out "$RESULTS" \
  --runs "$RUNS" --usage "$USAGE" --checks "$T/checks.json"
[[ "$RC" -eq 1 ]] || fail "collect (g) exit $RC, want 1"
grep -q -- "--force" "$T/err" || fail "collect (g): $(cat "$T/err")"
run "$BENCH" collect run-checks --task "$TASK_ID" --out "$RESULTS" \
  --runs "$RUNS" --usage "$USAGE" --checks "$T/checks.json" --force
[[ "$RC" -eq 0 ]] || fail "collect (g) --force exit $RC: $(cat "$T/err")"

echo "=== collect (h) missing usage fields stay null ==="
run "$BENCH" collect run-nocost --task "$TASK_ID" --out "$RESULTS" \
  --runs "$RUNS" --usage "$USAGE"
[[ "$RC" -eq 0 ]] || fail "collect (h) exit $RC: $(cat "$T/err")"
python3 - "$RESULTS/bench-nocost/$TASK_ID.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = json.load(handle)
assert doc["wall_ms"] == 0, doc
assert doc["cost"] == {"cc_usd": None, "oc_tokens": None}, doc
print("collect (h) null costs ok")
PY

echo "=== collect (i) a conflicting profile exits 2 ==="
run "$BENCH" collect run-merged --task "$TASK_ID" --out "$RESULTS" \
  --runs "$RUNS" --usage "$USAGE" --profile other-profile
[[ "$RC" -eq 2 ]] || fail "collect (i) exit $RC, want 2"
grep -q "does not match" "$T/err" || fail "collect (i): $(cat "$T/err")"

echo "test_factory_bench: PASS"
