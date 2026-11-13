#!/usr/bin/env bash
# Parked runs save state and resume by themselves after a Claude Code limit.
# Offline: local bare origin, stubs, no network, no secrets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d /tmp/factory-run-resume-XXXXXX)"
trap 'rm -rf "$T"' EXIT
fail() { echo "test_run_resume: FAIL $*" >&2; exit 1; }

unset FACTORY_AGMSG_TEAM FACTORY_RUNS_DIR FACTORY_NOTIFY_DIR FACTORY_WORK_DIR \
  FACTORY_GROK_HOOK_DIR FACTORY_ORIGIN_REINIT FACTORY_MAX_ROUNDS \
  FACTORY_GROK_MODE FACTORY_GROK_STUB FACTORY_CLAUDE_GATE_STUB FACTORY_RESUME \
  FACTORY_PROVIDER_STATE_DIR || true
export GIT_AUTHOR_NAME=factory GIT_AUTHOR_EMAIL=factory@localhost
export GIT_COMMITTER_NAME=factory GIT_COMMITTER_EMAIL=factory@localhost

echo "=== part B-style fake root ==="
FAKE="$T/root"
mkdir -p "$FAKE/bin" "$FAKE/local/origin"
for f in factory-run-local factory-common.sh factory-feedback factory-notify \
  factory-stall-retry factory-resume; do
  cp "$ROOT/bin/$f" "$FAKE/bin/$f"
  chmod +x "$FAKE/bin/$f"
done

PREPARED="$FAKE/local/origin/t.git"
git init --bare -q -b main "$PREPARED"
SEED="$T/seed"
git init -q -b main "$SEED"
printf 'base\n' > "$SEED/README.md"
git -C "$SEED" add README.md
git -C "$SEED" commit -q -m base
git -C "$SEED" remote add origin "$PREPARED"
git -C "$SEED" push -q -u origin main
rm -rf "$SEED"

PROVIDER_STATE_FILE="$T/provider-state"
printf 'ok\n' > "$PROVIDER_STATE_FILE"
write_provider() { printf '%s\n' "$1" > "$PROVIDER_STATE_FILE"; }

cat > "$FAKE/bin/factory-provider-state" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"; shift || true
case "$cmd" in
  check)
    state="$(cat "${PROVIDER_STATE_FILE:?}" 2>/dev/null || echo ok)"
    if [[ "$state" == "limited" ]]; then
      echo "limited 9999999999 2099-01-01T00:00:00+00:00"
      exit 75
    fi
    echo "ok"
    ;;
  wait)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
SH

cat > "$FAKE/bin/factory-local-origin" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"; shift || true
case "$cmd" in
  clone)
    name="${1:-}"; dest="${2:-}"
    [[ -n "$name" && -n "$dest" ]] || exit 1
    rm -rf "$dest"
    git clone "$PREPARED_BARE" "$dest" >/dev/null 2>&1
    ;;
  init)
    ;;
  *)
    echo "factory-local-origin stub: bad command $cmd" >&2
    exit 1
    ;;
esac
SH

cat > "$FAKE/bin/factory-spec-step" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
repo="${1:?}"; id="${2:-}"
n=$(( $(cat "$SPEC_COUNTER" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$SPEC_COUNTER"
printf 'spec %s\n' "$n" >> "${STEP_LOG:?}"
git -C "$repo" checkout -B "factory/${id}" >/dev/null 2>&1 || true
printf 'spec %s\n' "$n" >> "$repo/SPEC_RUNS.txt"
git -C "$repo" add SPEC_RUNS.txt
git -C "$repo" -c user.email=factory@localhost -c user.name=factory commit -q -m "spec $n" || true
if [[ -n "${SPEC_FAIL_AT:-}" && "$n" -eq "${SPEC_FAIL_AT}" ]]; then
  echo "spec stub failure n=$n" >&2
  exit 75
fi
SH

cat > "$FAKE/bin/factory-impl-step" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
repo="${1:?}"
n=$(( $(cat "$IMPL_COUNTER" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$IMPL_COUNTER"
printf 'impl %s\n' "$n" >> "${STEP_LOG:?}"
printf 'impl %s\n' "$n" >> "$repo/IMPL.txt"
git -C "$repo" add IMPL.txt
git -C "$repo" -c user.email=factory@localhost -c user.name=factory commit -q -m "impl $n"
SH

cat > "$FAKE/bin/factory-guard" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${STEP_LOG:?}"
echo "guard ok"
exit 0
SH

cat > "$FAKE/bin/factory-ci" <<'SH'
#!/usr/bin/env bash
printf 'ci\n' >> "${STEP_LOG:?}"
echo "ci ok"
exit 0
SH

cat > "$FAKE/bin/factory-gate-claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
n=$(( $(cat "$GATE_CLAUDE_COUNTER" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$GATE_CLAUDE_COUNTER"
printf 'gate-claude\n' >> "${STEP_LOG:?}"
read -r -a codes <<< "${GATE_CLAUDE_CODES:-0}"
idx=$((n - 1))
if [[ "$idx" -ge "${#codes[@]}" ]]; then idx=$(( ${#codes[@]} - 1 )); fi
ec="${codes[$idx]}"
echo "gate-claude attempt=$n ec=$ec"
if [[ "$ec" -ne 0 ]]; then
  printf '{"text":"GATE: FAIL\\nstub"}\n' > "${FACTORY_GATE_CLAUDE_OUT:-/tmp/factory-gate-claude.json}"
fi
exit "$ec"
SH

cat > "$FAKE/bin/factory-gate-grok" <<'SH'
#!/usr/bin/env bash
n=$(( $(cat "$GROK_COUNTER" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$GROK_COUNTER"
printf 'gate-grok\n' >> "${STEP_LOG:?}"
read -r -a codes <<< "${GROK_CODES:-0}"
idx=$((n - 1))
if [[ "$idx" -ge "${#codes[@]}" ]]; then idx=$(( ${#codes[@]} - 1 )); fi
ec="${codes[$idx]}"
echo "gate-grok attempt=$n ec=$ec"
exit "$ec"
SH

cat > "$FAKE/bin/factory-merge" <<'SH'
#!/usr/bin/env bash
n=$(( $(cat "$MERGE_COUNTER" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$MERGE_COUNTER"
printf 'merge\n' >> "${STEP_LOG:?}"
echo "merge ok"
exit 0
SH

cat > "$FAKE/bin/factory-status" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "$FAKE/bin/factory-labels" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "$FAKE/bin/factory-usage" <<'SH'
#!/usr/bin/env bash
exit 0
SH

chmod +x "$FAKE/bin"/*

run_factory() {
  local name="$1"; shift
  RUN_WORK="$T/work-$name"
  RUN_RUNS="$T/runs-$name"
  RUN_NOTIFY="$T/notify-$name"
  mkdir -p "$RUN_RUNS" "$RUN_NOTIFY"
  set +e
  env \
    FACTORY_ROOT="$FAKE" \
    FACTORY_TARGET_NAME=t \
    FACTORY_WORK_DIR="$RUN_WORK" \
    FACTORY_RUNS_DIR="$RUN_RUNS" \
    FACTORY_NOTIFY_DIR="$RUN_NOTIFY" \
    FACTORY_GROK_HOOK_DIR="$T/hooks-$name" \
    FACTORY_GATE_CLAUDE_OUT="$T/gate-claude-$name.json" \
    FACTORY_STALL_TIMEOUT_SEC=30 \
    PREPARED_BARE="$PREPARED" \
    PROVIDER_STATE_FILE="$PROVIDER_STATE_FILE" \
    SPEC_COUNTER="$T/spec-count-$name" \
    IMPL_COUNTER="$T/impl-count-$name" \
    GATE_CLAUDE_COUNTER="$T/gate-claude-count-$name" \
    GROK_COUNTER="$T/grok-count-$name" \
    MERGE_COUNTER="$T/merge-count-$name" \
    STEP_LOG="$T/steps-$name.log" \
    "$@" \
    "$FAKE/bin/factory-run-local" "$name" "brief for $name" >"$T/log-$name" 2>&1
  RUN_RC=$?
  set -e
}

run_resume() {
  local name="$1"; shift
  local resume_args=()
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --dry-run) resume_args+=(--dry-run) ;;
      *) fail "run_resume: bad argument: $1" ;;
    esac
    shift
  done
  set +e
  env \
    FACTORY_ROOT="$FAKE" \
    FACTORY_WORK_DIR="$T/work-$name" \
    FACTORY_RUNS_DIR="$T/runs-$name" \
    FACTORY_NOTIFY_DIR="$T/notify-$name" \
    FACTORY_GROK_HOOK_DIR="$T/hooks-$name" \
    FACTORY_GATE_CLAUDE_OUT="$T/gate-claude-$name.json" \
    FACTORY_STALL_TIMEOUT_SEC=30 \
    PREPARED_BARE="$PREPARED" \
    PROVIDER_STATE_FILE="$PROVIDER_STATE_FILE" \
    SPEC_COUNTER="$T/spec-count-$name" \
    IMPL_COUNTER="$T/impl-count-$name" \
    GATE_CLAUDE_COUNTER="$T/gate-claude-count-$name" \
    GROK_COUNTER="$T/grok-count-$name" \
    MERGE_COUNTER="$T/merge-count-$name" \
    STEP_LOG="$T/steps-$name.log" \
    GATE_CLAUDE_CODES="${GATE_CODES_RESUME:-0}" \
    "$FAKE/bin/factory-resume" "${resume_args[@]}" >"$T/resume-$name.log" 2>&1
  RESUME_RC=$?
  set -e
}

state_value() {
  python3 - "$1/state.json" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    value = json.load(fh)
for key in sys.argv[2].split("."):
    value = value.get(key) if isinstance(value, dict) else None
print("" if value is None else value)
PY
}

assert_state() {
  local run_dir="$1" key="$2" want="$3" got
  got="$(state_value "$run_dir" "$key")"
  [[ "$got" == "$want" ]] || fail "state $key=$got, want $want ($run_dir/state.json)"
}

echo "=== (a) gate limit parks, resume finishes without rerunning IMPL ==="
write_provider ok
run_factory a FACTORY_SKIP_CC_SPEC=1 GATE_CLAUDE_CODES="75 75"
[[ "$RUN_RC" -eq 75 ]] || fail "case a: initial exit $RUN_RC, want 75: $(cat "$T/log-a")"
assert_state "$RUN_RUNS/a" stage "gate-claude"
assert_state "$RUN_RUNS/a" exit "75"
assert_state "$RUN_RUNS/a" id "a"
assert_state "$RUN_RUNS/a" target "t"
assert_state "$RUN_RUNS/a" round "1"
[[ -n "$(state_value "$RUN_RUNS/a" sha)" ]] || fail "case a: state sha is empty"
[[ -n "$(state_value "$RUN_RUNS/a" updated_at)" ]] || fail "case a: state updated_at is empty"
[[ -f "$RUN_RUNS/a/brief.txt" ]] || fail "case a: brief.txt was not written"
[[ "$(cat "$RUN_RUNS/a/brief.txt")" == "brief for a" ]] || fail "case a: brief.txt content changed"
[[ "$(cat "$T/impl-count-a")" -eq 1 ]] || fail "case a: initial impl count was not 1"

echo "=== (d) --dry-run lists the run and calls no steps ==="
gate_before="$(cat "$T/gate-claude-count-a")"
run_resume a --dry-run
[[ "$RESUME_RC" -eq 0 ]] || fail "case d: exit $RESUME_RC, want 0: $(cat "$T/resume-a.log")"
grep -q 'resumed a exit=75' "$T/resume-a.log" || fail "case d: dry-run did not print the run id"
[[ ! -e "$T/merge-count-a" ]] || fail "case d: dry-run called merge"
[[ "$(cat "$T/gate-claude-count-a")" -eq "$gate_before" ]] || fail "case d: dry-run called gate"
assert_state "$RUN_RUNS/a" exit "75"

echo "=== (a) resume from gate-claude skips IMPL/GUARD/CI and merges ==="
GATE_CODES_RESUME=0 run_resume a
[[ "$RESUME_RC" -eq 0 ]] || fail "case a: resume exit $RESUME_RC, want 0: $(cat "$T/resume-a.log")"
grep -q 'resumed a exit=0' "$T/resume-a.log" || fail "case a: missing resumed line"
assert_state "$RUN_RUNS/a" exit "0"
assert_state "$RUN_RUNS/a" stage "merge"
[[ "$(cat "$T/impl-count-a")" -eq 1 ]] || fail "case a: resume reran IMPL ($(cat "$T/impl-count-a") total)"
[[ "$(cat "$T/merge-count-a")" -eq 1 ]] || fail "case a: merge ran $(cat "$T/merge-count-a") times, want 1"
if grep -q '=== ROUND 1 IMPL ===' "$T/resume-a.log"; then
  fail "case a: resume ran the IMPL stage"
fi

echo "=== (b) a limited provider stops before any step stub runs ==="
mkdir -p "$T/runs-b/b"
cat > "$T/runs-b/b/state.json" <<'JSON'
{"exit": 75, "grok_mode": null, "grok_stub": "pass", "id": "b", "round": 1, "sha": null, "stage": "gate-claude", "target": "t", "updated_at": "2026-01-01T00:00:00+00:00"}
JSON
printf 'brief for b\n' > "$T/runs-b/b/brief.txt"
write_provider limited
run_resume b
[[ "$RESUME_RC" -eq 75 ]] || fail "case b: exit $RESUME_RC, want 75: $(cat "$T/resume-b.log")"
grep -q 'limited ' "$T/resume-b.log" || fail "case b: provider limited line was not printed"
[[ ! -e "$T/steps-b.log" ]] || fail "case b: a step stub ran: $(cat "$T/steps-b.log")"
[[ ! -e "$T/runs-b/b/.resume.lock" ]] || fail "case b: factory-resume took the lock while limited"
assert_state "$T/runs-b/b" exit "75"
write_provider ok

echo "=== (c) a spec-stage park reruns SPEC and then completes ==="
run_factory c SPEC_FAIL_AT=1 GATE_CLAUDE_CODES=0
[[ "$RUN_RC" -eq 75 ]] || fail "case c: initial exit $RUN_RC, want 75: $(cat "$T/log-c")"
assert_state "$RUN_RUNS/c" stage "spec"
assert_state "$RUN_RUNS/c" exit "75"
[[ "$(cat "$T/spec-count-c")" -eq 1 ]] || fail "case c: initial spec count was not 1"
if git -C "$T/work-c" rev-parse -q --verify "refs/tags/spec/c" >/dev/null 2>&1; then
  fail "case c: spec tag exists after a failed SPEC"
fi

run_resume c
[[ "$RESUME_RC" -eq 0 ]] || fail "case c: resume exit $RESUME_RC, want 0: $(cat "$T/resume-c.log")"
grep -q 'resumed c exit=0' "$T/resume-c.log" || fail "case c: missing resumed line"
assert_state "$RUN_RUNS/c" exit "0"
[[ "$(cat "$T/spec-count-c")" -eq 2 ]] || fail "case c: SPEC did not rerun ($(cat "$T/spec-count-c") total)"
[[ "$(cat "$T/impl-count-c")" -eq 1 ]] || fail "case c: IMPL did not run once"
[[ "$(cat "$T/merge-count-c")" -eq 1 ]] || fail "case c: merge did not run once"

echo "=== (e) existing run-local tests still pass ==="
env -u FACTORY_ROOT -u FACTORY_RUNS_DIR -u FACTORY_NOTIFY_DIR -u FACTORY_WORK_DIR \
  -u FACTORY_RESUME -u FACTORY_PROVIDER_STATE_DIR \
  bash "$ROOT/local/tests/test_goal_entry.sh"
env -u FACTORY_ROOT -u FACTORY_RUNS_DIR -u FACTORY_NOTIFY_DIR -u FACTORY_WORK_DIR \
  -u FACTORY_RESUME -u FACTORY_PROVIDER_STATE_DIR \
  bash "$ROOT/local/tests/test_run_feedback.sh"

echo "test_run_resume: PASS"
