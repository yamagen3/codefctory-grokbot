#!/usr/bin/env bash
# Parked, in-flight, and orphaned runs: state, locks, and resume after a Claude Code limit.
# Offline: local bare origin, stubs, no network, no secrets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d /tmp/factory-run-resume-XXXXXX)"
trap 'rm -rf "$T"' EXIT
fail() { echo "test_run_resume: FAIL $*" >&2; exit 1; }

unset FACTORY_AGMSG_TEAM FACTORY_RUNS_DIR FACTORY_NOTIFY_DIR FACTORY_WORK_DIR \
  FACTORY_GROK_HOOK_DIR FACTORY_ORIGIN_REINIT FACTORY_MAX_ROUNDS \
  FACTORY_GROK_MODE FACTORY_GROK_STUB FACTORY_CLAUDE_GATE_STUB FACTORY_RESUME \
  FACTORY_PROVIDER_STATE_DIR FACTORY_RESUME_ORPHAN_SEC || true
export GIT_AUTHOR_NAME=factory GIT_AUTHOR_EMAIL=factory@localhost
export GIT_COMMITTER_NAME=factory GIT_COMMITTER_EMAIL=factory@localhost

echo "=== fake root ==="
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
state="$(cat "${PROVIDER_STATE_FILE:?}" 2>/dev/null || echo ok)"
case "$cmd" in
  check)
    if [[ "$state" == "limited" ]]; then
      echo "limited 9999999999 2099-01-01T00:00:00+00:00"
      exit 75
    fi
    echo "ok"
    ;;
  wait)
    [[ "$state" == "limited" ]] && exit 75
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
if [[ -n "${GATE_CLAUDE_BLOCK_FIFO:-}" ]]; then
  : > "${GATE_CLAUDE_BLOCK_READY:?}"
  read -r _ < "$GATE_CLAUDE_BLOCK_FIFO" || true
fi
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
  local resume_args=() extra_env=()
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --dry-run) resume_args+=(--dry-run) ;;
      *=*) extra_env+=("$1") ;;
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
    "${extra_env[@]}" \
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

notify_glob() {
  compgen -G "$1/*-$2.txt" || true
}

notify_count() {
  local files
  files="$(compgen -G "$1/*-$2.txt" || true)"
  if [[ -z "$files" ]]; then
    echo 0
  else
    printf '%s\n' "$files" | wc -l | tr -d ' '
  fi
}

wait_for_file() {
  local path="$1" tries="${2:-200}" i
  for ((i = 0; i < tries; i++)); do
    [[ -e "$path" ]] && return 0
    sleep 0.05
  done
  return 1
}

echo "=== (a) gate exits 75 with a limited provider: no gate-unavailable notification ==="
write_provider limited
run_factory a FACTORY_SKIP_CC_SPEC=1 GATE_CLAUDE_CODES="75 75"
[[ "$RUN_RC" -eq 75 ]] || fail "case a: initial exit $RUN_RC, want 75: $(cat "$T/log-a")"
assert_state "$RUN_RUNS/a" stage "gate-claude"
assert_state "$RUN_RUNS/a" exit "75"
assert_state "$RUN_RUNS/a" work "$T/work-a"
assert_state "$RUN_RUNS/a" max_rounds "3"
[[ -z "$(notify_glob "$RUN_NOTIFY" gate-unavailable)" ]] \
  || fail "case a: gate-unavailable notified while the provider was limited"
write_provider ok

echo "=== (b) gate exits 75 with an ok provider: notification is sent ==="
run_factory b FACTORY_SKIP_CC_SPEC=1 GATE_CLAUDE_CODES="75 75"
[[ "$RUN_RC" -eq 75 ]] || fail "case b: initial exit $RUN_RC, want 75: $(cat "$T/log-b")"
assert_state "$RUN_RUNS/b" exit "75"
gate_notice="$(notify_glob "$RUN_NOTIFY" gate-unavailable)"
[[ -n "$gate_notice" ]] || fail "case b: missing gate-unavailable notification"
grep -Fq 'id=b' $gate_notice || fail "case b: notification lost id=b"

echo "=== (c) a resume in flight keeps the parked round and sha ==="
run_factory c FACTORY_SKIP_CC_SPEC=1 GATE_CLAUDE_CODES="75 75"
[[ "$RUN_RC" -eq 75 ]] || fail "case c: initial exit $RUN_RC, want 75: $(cat "$T/log-c")"
assert_state "$RUN_RUNS/c" stage "gate-claude"
assert_state "$RUN_RUNS/c" exit "75"
orig_round="$(state_value "$RUN_RUNS/c" round)"
orig_sha="$(state_value "$RUN_RUNS/c" sha)"
[[ -n "$orig_sha" ]] || fail "case c: parked state has no sha"

gate_before="$(cat "$T/gate-claude-count-c")"
run_resume c --dry-run
[[ "$RESUME_RC" -eq 0 ]] || fail "case c: dry-run exit $RESUME_RC, want 0: $(cat "$T/resume-c.log")"
grep -q 'resumed c exit=75' "$T/resume-c.log" || fail "case c: dry-run did not list the run"
[[ "$(cat "$T/gate-claude-count-c")" -eq "$gate_before" ]] || fail "case c: dry-run called the gate"

FIFO="$T/gate-c.fifo"
READY="$T/gate-c.ready"
mkfifo "$FIFO"
run_resume c GATE_CLAUDE_CODES=0 GATE_CLAUDE_BLOCK_FIFO="$FIFO" \
  GATE_CLAUDE_BLOCK_READY="$READY" &
resume_pid=$!
wait_for_file "$READY" || fail "case c: resume never reached the blocking gate"
assert_state "$RUN_RUNS/c" stage "gate-claude"
assert_state "$RUN_RUNS/c" round "$orig_round"
assert_state "$RUN_RUNS/c" sha "$orig_sha"

echo "=== (d) a second run-local while (c) is blocked exits 75 and leaves HEAD alone ==="
head_before="$(git -C "$T/work-c" rev-parse HEAD)"
run_factory c FACTORY_SKIP_CC_SPEC=1 GATE_CLAUDE_CODES=0
[[ "$RUN_RC" -eq 75 ]] || fail "case d: second run exit $RUN_RC, want 75: $(cat "$T/log-c")"
grep -q 'factory-run-local: id=c is already running' "$T/log-c" \
  || fail "case d: second run did not report the run lock"
[[ "$(git -C "$T/work-c" rev-parse HEAD)" == "$head_before" ]] \
  || fail "case d: second run changed the work tree HEAD"
assert_state "$RUN_RUNS/c" round "$orig_round"
assert_state "$RUN_RUNS/c" sha "$orig_sha"

printf 'go\n' > "$FIFO"
set +e
wait "$resume_pid"
resume_wait_ec=$?
set -e
[[ "$resume_wait_ec" -eq 0 ]] || fail "case d: blocked resume exited $resume_wait_ec"
grep -q 'resumed c exit=0' "$T/resume-c.log" || fail "case d: resume did not finish"
assert_state "$RUN_RUNS/c" exit "0"
[[ "$(cat "$T/impl-count-c")" -eq 1 ]] || fail "case d: resume reran IMPL"
[[ "$(cat "$T/merge-count-c")" -eq 1 ]] || fail "case d: resume did not merge"

echo "=== (e) an old null-exit run is orphaned exactly once ==="
mkdir -p "$T/runs-e/e"
cat > "$T/runs-e/e/state.json" <<JSON
{"exit": null, "grok_mode": null, "grok_stub": "pass", "id": "e", "max_rounds": 3, "round": 2, "sha": "deadbeef", "stage": "impl", "target": "t", "updated_at": "2000-01-01T00:00:00+00:00", "work": "$T/work-e"}
JSON
write_provider ok
run_resume e --dry-run
[[ "$RESUME_RC" -eq 0 ]] || fail "case e: dry-run exit $RESUME_RC: $(cat "$T/resume-e.log")"
grep -q '^orphaned e stage=impl$' "$T/resume-e.log" || fail "case e: dry-run did not print orphaned"
assert_state "$T/runs-e/e" exit ""
[[ "$(notify_count "$T/notify-e" run-aborted)" -eq 0 ]] || fail "case e: dry-run notified"

run_resume e
[[ "$RESUME_RC" -eq 0 ]] || fail "case e: exit $RESUME_RC: $(cat "$T/resume-e.log")"
grep -q '^orphaned e stage=impl$' "$T/resume-e.log" || fail "case e: missing orphaned line"
assert_state "$T/runs-e/e" exit "137"
assert_state "$T/runs-e/e" stage "impl"
assert_state "$T/runs-e/e" round "2"
aborted="$(notify_glob "$T/notify-e" run-aborted)"
[[ -n "$aborted" ]] || fail "case e: missing run-aborted notification"
grep -Fq 'id=e orphaned stage=impl round=2' $aborted \
  || fail "case e: run-aborted message lost its fields"

run_resume e
[[ "$RESUME_RC" -eq 0 ]] || fail "case e: second exit $RESUME_RC: $(cat "$T/resume-e.log")"
if grep -q '^orphaned ' "$T/resume-e.log"; then
  fail "case e: second call orphaned the state again"
fi
assert_state "$T/runs-e/e" exit "137"
[[ "$(notify_count "$T/notify-e" run-aborted)" -eq 1 ]] \
  || fail "case e: run-aborted count is $(notify_count "$T/notify-e" run-aborted), want 1"
[[ "$(grep -c 'run-aborted' "$T/notify-e/NOTIFY.log")" -eq 1 ]] \
  || fail "case e: run-aborted was sent more than once"

echo "=== (f) an old null-exit run with a held run lock is left alone ==="
mkdir -p "$T/runs-f/f"
cat > "$T/runs-f/f/state.json" <<JSON
{"exit": null, "grok_mode": null, "grok_stub": "pass", "id": "f", "max_rounds": 3, "round": 1, "sha": "cafebabe", "stage": "impl", "target": "t", "updated_at": "2000-01-01T00:00:00+00:00", "work": "$T/work-f"}
JSON
HOLD_FIFO="$T/hold-f.fifo"
mkfifo "$HOLD_FIFO"
(
  exec 8>"$T/runs-f/f/.run.lock"
  flock -n 8 || exit 1
  : > "$T/lock-f.ready"
  read -r _ < "$HOLD_FIFO" || true
) &
holder_pid=$!
wait_for_file "$T/lock-f.ready" || fail "case f: lock holder did not start"
updated_before="$(state_value "$T/runs-f/f" updated_at)"
run_resume f
[[ "$RESUME_RC" -eq 0 ]] || fail "case f: exit $RESUME_RC: $(cat "$T/resume-f.log")"
if grep -q '^orphaned ' "$T/resume-f.log"; then
  fail "case f: orphaned a state whose run lock was held"
fi
assert_state "$T/runs-f/f" exit ""
[[ "$(state_value "$T/runs-f/f" updated_at)" == "$updated_before" ]] \
  || fail "case f: state was touched while the run lock was held"
[[ "$(notify_count "$T/notify-f" run-aborted)" -eq 0 ]] \
  || fail "case f: orphan notification sent while the run lock was held"
printf 'release\n' > "$HOLD_FIFO"
wait "$holder_pid" || true

echo "=== (g) a run with a custom work dir resumes and merges ==="
CUSTOM_WORK="$T/custom-work-g"
run_factory g FACTORY_SKIP_CC_SPEC=1 GATE_CLAUDE_CODES="75 75" \
  FACTORY_WORK_DIR="$CUSTOM_WORK" FACTORY_MAX_ROUNDS=4
[[ "$RUN_RC" -eq 75 ]] || fail "case g: initial exit $RUN_RC, want 75: $(cat "$T/log-g")"
assert_state "$RUN_RUNS/g" exit "75"
assert_state "$RUN_RUNS/g" work "$CUSTOM_WORK"
assert_state "$RUN_RUNS/g" max_rounds "4"
[[ -e "$CUSTOM_WORK/.git" ]] || fail "case g: custom work tree missing"
[[ ! -e "$T/work-g/.git" ]] || fail "case g: default work tree exists unexpectedly"

GATE_CODES_RESUME=0 run_resume g FACTORY_MAX_ROUNDS=99
[[ "$RESUME_RC" -eq 0 ]] || fail "case g: resume exit $RESUME_RC: $(cat "$T/resume-g.log")"
grep -q 'resumed g exit=0' "$T/resume-g.log" || fail "case g: missing resumed line"
assert_state "$RUN_RUNS/g" exit "0"
assert_state "$RUN_RUNS/g" work "$CUSTOM_WORK"
assert_state "$RUN_RUNS/g" max_rounds "4"
[[ "$(cat "$T/merge-count-g")" -eq 1 ]] || fail "case g: resume did not merge"

echo "=== regression: a limited provider stops before any step stub runs ==="
mkdir -p "$T/runs-lim/lim"
cat > "$T/runs-lim/lim/state.json" <<'JSON'
{"exit": 75, "grok_mode": null, "grok_stub": "pass", "id": "lim", "round": 1, "sha": null, "stage": "gate-claude", "target": "t", "updated_at": "2026-01-01T00:00:00+00:00"}
JSON
printf 'brief for lim\n' > "$T/runs-lim/lim/brief.txt"
write_provider limited
run_resume lim
[[ "$RESUME_RC" -eq 75 ]] || fail "case lim: exit $RESUME_RC, want 75: $(cat "$T/resume-lim.log")"
grep -q 'limited ' "$T/resume-lim.log" || fail "case lim: provider limited line was not printed"
[[ ! -e "$T/steps-lim.log" ]] || fail "case lim: a step stub ran: $(cat "$T/steps-lim.log")"
[[ ! -e "$T/runs-lim/lim/.resume.lock" ]] || fail "case lim: resume lock taken while limited"
assert_state "$T/runs-lim/lim" exit "75"
write_provider ok

echo "=== regression: a spec-stage park reruns SPEC and then completes ==="
run_factory spec SPEC_FAIL_AT=1 GATE_CLAUDE_CODES=0
[[ "$RUN_RC" -eq 75 ]] || fail "case spec: initial exit $RUN_RC, want 75: $(cat "$T/log-spec")"
assert_state "$RUN_RUNS/spec" stage "spec"
assert_state "$RUN_RUNS/spec" exit "75"
[[ "$(cat "$T/spec-count-spec")" -eq 1 ]] || fail "case spec: initial spec count was not 1"
if git -C "$T/work-spec" rev-parse -q --verify "refs/tags/spec/spec" >/dev/null 2>&1; then
  fail "case spec: spec tag exists after a failed SPEC"
fi
run_resume spec
[[ "$RESUME_RC" -eq 0 ]] || fail "case spec: resume exit $RESUME_RC: $(cat "$T/resume-spec.log")"
assert_state "$RUN_RUNS/spec" exit "0"
[[ "$(cat "$T/spec-count-spec")" -eq 2 ]] || fail "case spec: SPEC did not rerun"
[[ "$(cat "$T/impl-count-spec")" -eq 1 ]] || fail "case spec: IMPL did not run once"
[[ "$(cat "$T/merge-count-spec")" -eq 1 ]] || fail "case spec: merge did not run once"

echo "=== (h) existing run-local tests still pass ==="
env -u FACTORY_ROOT -u FACTORY_RUNS_DIR -u FACTORY_NOTIFY_DIR -u FACTORY_WORK_DIR \
  -u FACTORY_RESUME -u FACTORY_PROVIDER_STATE_DIR -u FACTORY_MAX_ROUNDS \
  -u FACTORY_RESUME_ORPHAN_SEC \
  bash "$ROOT/local/tests/test_goal_entry.sh"
env -u FACTORY_ROOT -u FACTORY_RUNS_DIR -u FACTORY_NOTIFY_DIR -u FACTORY_WORK_DIR \
  -u FACTORY_RESUME -u FACTORY_PROVIDER_STATE_DIR -u FACTORY_MAX_ROUNDS \
  -u FACTORY_RESUME_ORPHAN_SEC \
  bash "$ROOT/local/tests/test_run_feedback.sh"

echo "test_run_resume: PASS"
