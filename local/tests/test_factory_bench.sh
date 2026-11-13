#!/usr/bin/env bash
# factory-bench: validate the seed tasks and score stub results offline.
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

echo "test_factory_bench: PASS"
