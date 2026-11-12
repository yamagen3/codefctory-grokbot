#!/usr/bin/env bash
# factory-continue: auto-merge after a recorded Grok success, reject on failure,
# and stay idempotent. Fully offline: local bare origin + local backend.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="$ROOT/bin:$PATH"
export FACTORY_ROOT="$ROOT"
export GIT_AUTHOR_NAME=factory GIT_AUTHOR_EMAIL=factory@localhost
export GIT_COMMITTER_NAME=factory GIT_COMMITTER_EMAIL=factory@localhost
FIX="$(mktemp -d /tmp/factory-continue-XXXXXX)"
trap 'rm -rf "$FIX"' EXIT

fail() { echo "test_factory_continue: FAIL $*" >&2; exit 1; }

export FACTORY_STATUS_DIR="$FIX/status"
export FACTORY_LABELS_DIR="$FIX/labels"
export FACTORY_PR_DIR="$FIX/prs"
export FACTORY_GROK_HOOK_DIR="$FIX/hooks"
export FACTORY_NOTIFY_DIR="$FIX/notify"
export FACTORY_USAGE_DIR="$FIX/usage"
mkdir -p "$FACTORY_GROK_HOOK_DIR" "$FACTORY_NOTIFY_DIR"
unset FACTORY_BACKEND FACTORY_AGMSG_TEAM FACTORY_GROK_STUB FACTORY_GROK_MODE

# Bare origin + work repo with main pushed.
git init --bare -b main "$FIX/origin.git" >/dev/null
git init -b main "$FIX/seed" >/dev/null
printf 'base\n' > "$FIX/seed/README.md"
git -C "$FIX/seed" add README.md
git -C "$FIX/seed" commit -q -m base
git -C "$FIX/seed" remote add origin "$FIX/origin.git"
git -C "$FIX/seed" push -q -u origin main
rm -rf "$FIX/seed"
git clone -q "$FIX/origin.git" "$FIX/work"
WORK="$FIX/work"

origin_main() { git --git-dir="$FIX/origin.git" rev-parse refs/heads/main; }
has_notify() { compgen -G "$FACTORY_NOTIFY_DIR/*-$1.txt" >/dev/null; }
marker() { echo "$FACTORY_GROK_HOOK_DIR/continued-$1.json"; }

new_branch() {
  local id="$1" sha
  git -C "$WORK" checkout -q main
  git -C "$WORK" checkout -q -B "factory/$id"
  printf '%s\n' "$id" >> "$WORK/README.md"
  git -C "$WORK" add README.md
  git -C "$WORK" commit -q -m "work $id"
  git -C "$WORK" tag -f "spec/$id" HEAD^ >/dev/null
  sha=$(git -C "$WORK" rev-parse HEAD)
  printf '%s\n' "$sha"
}

gate_pending() {
  local id="$1" sha="$2" rc
  set +e
  FACTORY_GROK_MODE=pending factory-gate-grok "$WORK" "$id" "$sha" >"$FIX/gate-$id.log" 2>&1
  rc=$?
  set -e
  [[ "$rc" == 2 ]] || fail "case $id: pending gate exited $rc (want 2)"
}

status_ok() {
  factory-status set "$WORK" "$1" "$2" success ok >/dev/null
}

# Case A: pending gate, then a recorded success auto-continues and merges once.
SHA_A=$(new_branch t1)
gate_pending t1 "$SHA_A"
status_ok "$SHA_A" guard
status_ok "$SHA_A" ci
status_ok "$SHA_A" "gate/claude"
factory-gate-grok record "$SHA_A" success ok >"$FIX/record-t1.log" 2>&1
git --git-dir="$FIX/origin.git" merge-base --is-ancestor "$SHA_A" refs/heads/main \
  || fail "case A: $SHA_A is not an ancestor of origin main"
has_notify merged || fail "case A: no merged notification"
[[ -f "$(marker "$SHA_A")" ]] || fail "case A: no continued marker"
BEFORE=$(origin_main)
factory-continue "$SHA_A" >"$FIX/continue-t1-second.log" 2>&1 \
  || fail "case A: second continue exited non-zero"
[[ "$(origin_main)" == "$BEFORE" ]] || fail "case A: second continue moved origin main"

# Case B: opt-out defers the failure; continue reports rejection and writes no merge.
SHA_B=$(new_branch t2)
gate_pending t2 "$SHA_B"
BEFORE=$(origin_main)
FACTORY_GROK_AUTO_CONTINUE=0 factory-gate-grok record "$SHA_B" failure "missing --help" \
  >"$FIX/record-t2.log" 2>&1
[[ ! -e "$(marker "$SHA_B")" ]] || fail "case B: opt-out still wrote a marker"
set +e
factory-continue "$SHA_B" >"$FIX/continue-t2.log" 2>&1
RC=$?
set -e
[[ "$RC" == 4 ]] || fail "case B: continue exited $RC (want 4)"
[[ "$(origin_main)" == "$BEFORE" ]] || fail "case B: origin main moved"
has_notify grok-rejected || fail "case B: no grok-rejected notification"
grep -q 'missing --help' "$FACTORY_NOTIFY_DIR"/*-grok-rejected.txt \
  || fail "case B: rejection reason missing from notification"
[[ -f "$(marker "$SHA_B")" ]] || fail "case B: no continued marker"

# Case C: pending record without a verdict.
SHA_C=$(new_branch t3)
gate_pending t3 "$SHA_C"
BEFORE=$(origin_main)
set +e
factory-continue "$SHA_C" >"$FIX/continue-t3.log" 2>&1
RC=$?
set -e
[[ "$RC" == 2 ]] || fail "case C: continue exited $RC (want 2)"
[[ ! -e "$(marker "$SHA_C")" ]] || fail "case C: marker written without a verdict"
[[ "$(origin_main)" == "$BEFORE" ]] || fail "case C: origin main moved"

# Case D: stub run is not continued automatically.
SHA_D=$(new_branch t4)
BEFORE=$(origin_main)
set +e
FACTORY_GROK_STUB=pass factory-gate-grok "$WORK" t4 "$SHA_D" >"$FIX/gate-t4.log" 2>&1
RC=$?
set -e
[[ "$RC" == 0 ]] || fail "case D: stub gate exited $RC (want 0): $(cat "$FIX/gate-t4.log")"
[[ ! -e "$(marker "$SHA_D")" ]] || fail "case D: stub wrote a marker"
[[ "$(origin_main)" == "$BEFORE" ]] || fail "case D: stub moved origin main"
grep -q 'not applicable' "$FIX/gate-t4.log" \
  || fail "case D: auto-continue did not report not applicable"

# Case E: recorded success but the ci status is missing, so merge fails.
SHA_E=$(new_branch t5)
gate_pending t5 "$SHA_E"
status_ok "$SHA_E" guard
status_ok "$SHA_E" "gate/claude"
BEFORE=$(origin_main)
FACTORY_GROK_AUTO_CONTINUE=0 factory-gate-grok record "$SHA_E" success ok \
  >"$FIX/record-t5.log" 2>&1
set +e
factory-continue "$SHA_E" >"$FIX/continue-t5.log" 2>&1
RC=$?
set -e
[[ "$RC" == 1 ]] || fail "case E: continue exited $RC (want 1)"
has_notify merge-failed || fail "case E: no merge-failed notification"
[[ ! -e "$(marker "$SHA_E")" ]] || fail "case E: merge failure wrote a marker"
[[ "$(origin_main)" == "$BEFORE" ]] || fail "case E: origin main moved"

echo "OK factory-continue"
