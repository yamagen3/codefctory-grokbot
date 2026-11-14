#!/usr/bin/env bash
# Profile enforcement at run start, state/usage recording, and tighter check.
# Offline: copied trees and fake roots with stubs; no model, network, or provider.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d /tmp/factory-run-profile-XXXXXX)"
trap 'rm -rf "$T"' EXIT
fail() { echo "test_run_profile: FAIL $*" >&2; exit 1; }

unset FACTORY_MODEL_PROFILE FACTORY_MODEL_PROFILE_ID FACTORY_ROOT FACTORY_RUNS_DIR \
  FACTORY_NOTIFY_DIR FACTORY_WORK_DIR FACTORY_RESUME FACTORY_USAGE_DIR \
  FACTORY_USAGE_RUN_ID FACTORY_TARGET_NAME FACTORY_USAGE_ROUND FACTORY_USAGE_STEP || true
export GIT_AUTHOR_NAME=factory GIT_AUTHOR_EMAIL=factory@localhost
export GIT_COMMITTER_NAME=factory GIT_COMMITTER_EMAIL=factory@localhost

PROFILE_FILES=(
  config/claude-code.json
  bin/factory-common.sh
  bin/factory-run-local
  bin/factory-stall-retry
  bin/factory-impl-step
  bin/factory-spec-step
  bin/factory-gate-claude
  bin/factory-profile
  lib/factory_usage.py
)

make_profile_tree() {
  local dest="$1" relative
  rm -rf "$dest"
  mkdir -p "$dest/config" "$dest/bin" "$dest/lib" "$dest/profiles"
  for relative in "${PROFILE_FILES[@]}"; do
    mkdir -p "$dest/$(dirname "$relative")"
    cp "$ROOT/$relative" "$dest/$relative"
  done
  cp "$ROOT/profiles/default.json" "$dest/profiles/default.json"
  chmod +x "$dest/bin/factory-profile"
}

run_profile() {
  local dest="$1"; shift
  FACTORY_ROOT="$dest" "$dest/bin/factory-profile" "$@"
}

echo "=== (a) the real checkout matches its profile ==="
out=$(FACTORY_ROOT="$ROOT" "$ROOT/bin/factory-profile" check) \
  || fail "(a) real checkout check failed: $out"
[[ "$out" == "ok" ]] || fail "(a) real checkout check printed: $out"

echo "=== (b) a model-line drift makes check fail ==="
TREE="$T/tree-model"
make_profile_tree "$TREE"
python3 - "$TREE/config/claude-code.json" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
want = '"model": "claude-opus-5-5"'
assert want in text, text
path.write_text(text.replace(want, '"model": "claude-opus-5-5-x"', 1))
PY
set +e
out=$(run_profile "$TREE" check 2>&1)
CHECK_RC=$?
set -e
[[ "$CHECK_RC" -eq 1 ]] || fail "(b) check exited $CHECK_RC, want 1: $out"
grep -q 'brain\.model' <<<"$out" || fail "(b) mismatch did not name brain.model: $out"

echo "=== (c) a PARALLEL drift makes check fail ==="
TREE="$T/tree-parallel"
make_profile_tree "$TREE"
python3 - "$TREE/bin/factory-impl-step" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
want = "PARALLEL=2"
assert text.count(want) >= 1, text
path.write_text(text.replace(want, "PARALLEL=3", 1))
PY
set +e
out=$(run_profile "$TREE" check 2>&1)
CHECK_RC=$?
set -e
[[ "$CHECK_RC" -eq 1 ]] || fail "(c) check exited $CHECK_RC, want 1: $out"
grep -q 'maker\.parallel_default' <<<"$out" \
  || fail "(c) mismatch did not name maker.parallel_default: $out"

# ---- fake roots for the runner ----
make_run_root() {
  local dest="$1" with_profile="$2"
  rm -rf "$dest"
  mkdir -p "$dest/bin" "$dest/local/origin"
  for f in factory-run-local factory-common.sh factory-feedback factory-notify factory-stall-retry; do
    cp "$ROOT/bin/$f" "$dest/bin/$f"
  done
  if [[ "$with_profile" == "1" ]]; then
    mkdir -p "$dest/profiles"
    printf '{"id":"default"}\n' > "$dest/profiles/default.json"
    cat > "$dest/bin/factory-profile" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  id)
    printf '%s\n' "${PROFILE_ID:-default}"
    ;;
  check)
    rc="${PROFILE_CHECK_RC:-0}"
    if [[ "$rc" -ne 0 ]]; then
      printf '%s\n' "${PROFILE_CHECK_TEXT:-brain.model: stale profile}"
      exit "$rc"
    fi
    echo ok
    ;;
  *)
    echo "factory-profile stub: bad command $cmd" >&2
    exit 2
    ;;
esac
SH
    chmod +x "$dest/bin/factory-profile"
  fi

  cat > "$dest/bin/factory-local-origin" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"; shift || true
case "$cmd" in
  init)
    ;;
  clone)
    name="${1:-}"; work="${2:-}"
    [[ -n "$name" && -n "$work" ]] || exit 1
    rm -rf "$work"
    git init -q -b main "$work"
    printf 'base\n' > "$work/README.md"
    git -C "$work" add README.md
    git -C "$work" -c user.email=factory@localhost -c user.name=factory commit -q -m base
    ;;
  *)
    echo "factory-local-origin stub: bad command $cmd" >&2
    exit 1
    ;;
esac
SH

  cat > "$dest/bin/factory-impl-step" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
repo="${1:?}"
printf '%s\n' "${FACTORY_MODEL_PROFILE_ID:-unset}" >> "${PROFILE_SEEN:?}"
printf 'impl\n' >> "${STEP_LOG:?}"
printf 'impl\n' >> "$repo/IMPL.txt"
git -C "$repo" add IMPL.txt
git -C "$repo" -c user.email=factory@localhost -c user.name=factory commit -q -m impl
SH

  for f in factory-guard factory-ci factory-gate-claude factory-gate-grok \
    factory-merge factory-status factory-labels factory-usage; do
    cat > "$dest/bin/$f" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  done
  chmod +x "$dest/bin"/*
}

run_factory() {
  local root="$1" name="$2"; shift 2
  RUN_WORK="$T/work-$name"
  RUN_RUNS="$T/runs-$name"
  RUN_NOTIFY="$T/notify-$name"
  mkdir -p "$RUN_RUNS" "$RUN_NOTIFY"
  set +e
  env \
    FACTORY_ROOT="$root" \
    FACTORY_TARGET_NAME=t \
    FACTORY_SKIP_CC_SPEC=1 \
    FACTORY_WORK_DIR="$RUN_WORK" \
    FACTORY_RUNS_DIR="$RUN_RUNS" \
    FACTORY_NOTIFY_DIR="$RUN_NOTIFY" \
    FACTORY_GROK_HOOK_DIR="$T/hooks-$name" \
    FACTORY_GATE_CLAUDE_OUT="$T/gate-claude-$name.json" \
    FACTORY_STALL_TIMEOUT_SEC=30 \
    STEP_LOG="$T/steps-$name.log" \
    PROFILE_SEEN="$T/profile-seen-$name.log" \
    "$@" \
    "$root/bin/factory-run-local" "$name" "brief for $name" >"$T/log-$name" 2>&1
  RUN_RC=$?
  set -e
}

run_resume_profile() {
  local root="$1" name="$2"; shift 2
  mkdir -p "$T/notify-$name"
  set +e
  env \
    FACTORY_ROOT="$root" \
    FACTORY_TARGET_NAME=t \
    FACTORY_RESUME=1 \
    FACTORY_WORK_DIR="$T/work-$name" \
    FACTORY_RUNS_DIR="$T/runs-$name" \
    FACTORY_NOTIFY_DIR="$T/notify-$name" \
    FACTORY_GROK_HOOK_DIR="$T/hooks-$name" \
    FACTORY_STALL_TIMEOUT_SEC=30 \
    STEP_LOG="$T/steps-$name.log" \
    PROFILE_SEEN="$T/profile-seen-$name.log" \
    "$@" \
    "$root/bin/factory-run-local" "$name" >"$T/log-$name" 2>&1
  RUN_RC=$?
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

state_has_null_profile() {
  python3 - "$1/state.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    doc = json.load(fh)
assert "profile" in doc, doc
assert doc["profile"] is None, doc
PY
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

FAKE="$T/root-profile"
FAKE_NOPROF="$T/root-no-profile"
make_run_root "$FAKE" 1
make_run_root "$FAKE_NOPROF" 0

echo "=== (d) a passing profile is recorded and exported to steps ==="
run_factory "$FAKE" d
[[ "$RUN_RC" -eq 0 ]] || fail "(d) run exited $RUN_RC, want 0: $(cat "$T/log-d")"
[[ "$(state_value "$T/runs-d/d" profile)" == "default" ]] \
  || fail "(d) state profile is not default"
grep -qx 'default' "$T/profile-seen-d.log" \
  || fail "(d) step did not see FACTORY_MODEL_PROFILE_ID=default: $(cat "$T/profile-seen-d.log")"

echo "=== (e) a failing check exits before any step and notifies run-aborted ==="
run_factory "$FAKE" e PROFILE_CHECK_RC=1
[[ "$RUN_RC" -eq 1 ]] || fail "(e) run exited $RUN_RC, want 1: $(cat "$T/log-e")"
grep -q 'profile does not match the live configuration' "$T/log-e" \
  || fail "(e) missing profile mismatch message"
[[ ! -e "$T/steps-e.log" ]] || fail "(e) a step ran: $(cat "$T/steps-e.log")"
[[ ! -e "$T/profile-seen-e.log" ]] || fail "(e) the impl stub ran"
[[ "$(state_value "$T/runs-e/e" exit)" == "1" ]] || fail "(e) state exit is not 1"
[[ "$(notify_count "$T/notify-e" run-aborted)" -eq 1 ]] \
  || fail "(e) run-aborted count is $(notify_count "$T/notify-e" run-aborted), want 1"

echo "=== (f) without profiles/ the runner keeps the null-profile path ==="
run_factory "$FAKE_NOPROF" f
[[ "$RUN_RC" -eq 0 ]] || fail "(f) run exited $RUN_RC, want 0: $(cat "$T/log-f")"
state_has_null_profile "$T/runs-f/f" || fail "(f) state profile is not null"
grep -qx 'unset' "$T/profile-seen-f.log" \
  || fail "(f) step saw a profile id: $(cat "$T/profile-seen-f.log")"

echo "=== (g) resume refuses a saved profile that differs from the active one ==="
mkdir -p "$T/work-g"
git init -q -b main "$T/work-g"
printf 'base\n' > "$T/work-g/README.md"
git -C "$T/work-g" add README.md
git -C "$T/work-g" -c user.email=factory@localhost -c user.name=factory commit -q -m base
mkdir -p "$T/runs-g/g"
cat > "$T/runs-g/g/state.json" <<JSON
{"exit": 75, "grok_mode": null, "grok_stub": "pass", "id": "g", "max_rounds": 3, "profile": "a", "round": 1, "sha": null, "stage": "impl", "target": "t", "updated_at": "2026-01-01T00:00:00+00:00", "work": "$T/work-g"}
JSON
run_resume_profile "$FAKE" g PROFILE_ID=b
[[ "$RUN_RC" -eq 1 ]] || fail "(g) resume exited $RUN_RC, want 1: $(cat "$T/log-g")"
grep -q 'profile does not match the live configuration' "$T/log-g" \
  || fail "(g) missing profile mismatch message"
[[ "$(state_value "$T/runs-g/g" profile)" == "a" ]] \
  || fail "(g) saved profile was overwritten"
[[ "$(state_value "$T/runs-g/g" exit)" == "1" ]] || fail "(g) state exit is not 1"
[[ ! -e "$T/steps-g.log" ]] || fail "(g) a step ran during the refused resume"

echo "=== (h) usage records the profile on steps and the run summary ==="
mkdir -p "$T/usage"
NOW=$(date -Iseconds)
printf '{"usage":{"input_tokens":1,"output_tokens":2}}\n' > "$T/usage-result.json"
env FACTORY_USAGE_DIR="$T/usage" FACTORY_ROOT="$ROOT" \
  FACTORY_USAGE_RUN_ID=run-profile FACTORY_TARGET_NAME=t FACTORY_USAGE_ROUND=1 FACTORY_USAGE_STEP=impl \
  "$ROOT/bin/factory-usage" record-step --provider claude-code --started "$NOW" --ended "$NOW" \
  --duration-ms 10 --exit 0 --result-file "$T/usage-result.json"
env FACTORY_USAGE_DIR="$T/usage" FACTORY_ROOT="$ROOT" FACTORY_MODEL_PROFILE_ID=default \
  FACTORY_USAGE_RUN_ID=run-profile FACTORY_TARGET_NAME=t FACTORY_USAGE_ROUND=2 FACTORY_USAGE_STEP=impl \
  "$ROOT/bin/factory-usage" record-step --provider claude-code --started "$NOW" --ended "$NOW" \
  --duration-ms 10 --exit 0 --result-file "$T/usage-result.json"
env FACTORY_USAGE_DIR="$T/usage" FACTORY_ROOT="$ROOT" \
  "$ROOT/bin/factory-usage" run-summary run-profile --wall-ms 10 --status merged --print >/dev/null
python3 - "$T/usage" <<'PY'
import glob
import json
import sys

steps = []
for path in glob.glob(sys.argv[1] + "/*/steps.jsonl"):
    with open(path, encoding="utf-8") as fh:
        steps.extend(json.loads(line) for line in fh if line.strip())
profiles = [r.get("profile") for r in steps if r.get("run_id") == "run-profile"]
assert profiles == [None, "default"], profiles

runs = []
for path in glob.glob(sys.argv[1] + "/*/runs.jsonl"):
    with open(path, encoding="utf-8") as fh:
        runs.extend(json.loads(line) for line in fh if line.strip())
summary = next(r for r in runs if r.get("run_id") == "run-profile")
assert summary.get("profile") == "default", summary
PY

echo "=== (i) existing run-local tests still pass ==="
env -u FACTORY_ROOT -u FACTORY_RUNS_DIR -u FACTORY_NOTIFY_DIR -u FACTORY_WORK_DIR \
  -u FACTORY_RESUME -u FACTORY_PROVIDER_STATE_DIR -u FACTORY_MAX_ROUNDS \
  -u FACTORY_RESUME_ORPHAN_SEC -u FACTORY_MODEL_PROFILE -u FACTORY_MODEL_PROFILE_ID \
  bash "$ROOT/local/tests/test_run_resume.sh"
env -u FACTORY_ROOT -u FACTORY_RUNS_DIR -u FACTORY_NOTIFY_DIR -u FACTORY_WORK_DIR \
  -u FACTORY_RESUME -u FACTORY_PROVIDER_STATE_DIR -u FACTORY_MAX_ROUNDS \
  -u FACTORY_RESUME_ORPHAN_SEC -u FACTORY_MODEL_PROFILE -u FACTORY_MODEL_PROFILE_ID \
  bash "$ROOT/local/tests/test_run_feedback.sh"

echo "test_run_profile: PASS"
