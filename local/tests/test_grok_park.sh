#!/usr/bin/env bash
# Grok gate parking, prefix resolution, and continue re-record behavior.
# Fully offline: local bare origin + local backend.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="$ROOT/bin:$PATH"
export FACTORY_ROOT="$ROOT"
export GIT_AUTHOR_NAME=factory GIT_AUTHOR_EMAIL=factory@localhost
export GIT_COMMITTER_NAME=factory GIT_COMMITTER_EMAIL=factory@localhost
FIX="$(mktemp -d /tmp/factory-grok-park-XXXXXX)"
trap 'rm -rf "$FIX"' EXIT

fail() { echo "test_grok_park: FAIL $*" >&2; exit 1; }

export FACTORY_STATUS_DIR="$FIX/status"
export FACTORY_LABELS_DIR="$FIX/labels"
export FACTORY_PR_DIR="$FIX/prs"
export FACTORY_GROK_HOOK_DIR="$FIX/hooks"
export FACTORY_NOTIFY_DIR="$FIX/notify"
export FACTORY_USAGE_DIR="$FIX/usage"
mkdir -p "$FACTORY_GROK_HOOK_DIR" "$FACTORY_NOTIFY_DIR"
unset FACTORY_BACKEND FACTORY_AGMSG_TEAM FACTORY_GROK_STUB FACTORY_GROK_MODE \
  FACTORY_GROK_ON_WAIT_TIMEOUT FACTORY_GROK_AUTO_CONTINUE

# Bare origin + work repo with main pushed (same fixture as test_factory_continue.sh).
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
notify_contains() {
  local kind="$1" needle="$2"
  grep -q -- "$needle" "$FACTORY_NOTIFY_DIR"/*-"$kind".txt 2>/dev/null
}
marker() { echo "$FACTORY_GROK_HOOK_DIR/continued-$1.json"; }
pending() { echo "$FACTORY_GROK_HOOK_DIR/pending-$1.json"; }
result() { echo "$FACTORY_GROK_HOOK_DIR/result-$1.json"; }

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

status_state() {
  factory-status all "$WORK" "$1" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("gate/grok",{}).get("state",""))'
}

marker_outcome() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("outcome",""))' "$(marker "$1")"
}

# P1: wait timeout parks the verdict as pending; a later success continues and merges.
SHA_P1=$(new_branch p1)
set +e
FACTORY_GROK_WAIT_SEC=1 FACTORY_GROK_POLL_SEC=1 FACTORY_GROK_MODE=wait \
  factory-gate-grok "$WORK" p1 "$SHA_P1" >"$FIX/gate-p1.log" 2>&1
RC=$?
set -e
[[ "$RC" == 2 ]] || fail "P1: wait/park exited $RC (want 2): $(cat "$FIX/gate-p1.log")"
[[ -f "$(pending "$SHA_P1")" ]] || fail "P1: no pending record"
python3 - "$(pending "$SHA_P1")" <<'PY' || fail "P1: pending record was not parked"
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec.get("mode") == "pending", rec
assert rec.get("parked_at"), rec
PY
has_notify grok-pending || fail "P1: no grok-pending notification"
notify_contains grok-pending "$SHA_P1" || fail "P1: grok-pending notification missing sha"
[[ "$(status_state "$SHA_P1")" == "pending" ]] || fail "P1: gate/grok not pending after park"
status_ok "$SHA_P1" guard
status_ok "$SHA_P1" ci
status_ok "$SHA_P1" "gate/claude"
factory-gate-grok record "$SHA_P1" success ok >"$FIX/record-p1.log" 2>&1 \
  || fail "P1: record success exited non-zero"
git --git-dir="$FIX/origin.git" merge-base --is-ancestor "$SHA_P1" refs/heads/main \
  || fail "P1: $SHA_P1 is not an ancestor of origin main"
[[ -f "$(marker "$SHA_P1")" ]] || fail "P1: no continued marker"

# P2: opt-in fail timeout keeps the old error path.
SHA_P2=$(new_branch p2)
set +e
FACTORY_GROK_WAIT_SEC=1 FACTORY_GROK_POLL_SEC=1 FACTORY_GROK_MODE=wait FACTORY_GROK_ON_WAIT_TIMEOUT=fail \
  factory-gate-grok "$WORK" p2 "$SHA_P2" >"$FIX/gate-p2.log" 2>&1
RC=$?
set -e
[[ "$RC" != 0 && "$RC" != 2 ]] || fail "P2: wait/fail exited $RC (want neither 0 nor 2)"
[[ "$(status_state "$SHA_P2")" == "error" ]] || fail "P2: gate/grok not error after wait failure"

# P3: plain pending mode announces the pending verdict with its sha.
SHA_P3=$(new_branch p3)
gate_pending p3 "$SHA_P3"
has_notify grok-pending || fail "P3: no grok-pending notification"
notify_contains grok-pending "$SHA_P3" || fail "P3: grok-pending notification missing sha"
grep -q "\"mode\": \"pending\"" "$(pending "$SHA_P3")" || fail "P3: pending record mode is not pending"

# P4: a unique prefix records against the full sha and merges.
SHA_P4=$(new_branch p4)
gate_pending p4 "$SHA_P4"
status_ok "$SHA_P4" guard
status_ok "$SHA_P4" ci
status_ok "$SHA_P4" "gate/claude"
factory-gate-grok record "${SHA_P4:0:12}" success ok >"$FIX/record-p4.log" 2>&1 \
  || fail "P4: prefix record exited non-zero"
[[ -f "$(result "$SHA_P4")" ]] || fail "P4: result file is not named for the full sha"
git --git-dir="$FIX/origin.git" merge-base --is-ancestor "$SHA_P4" refs/heads/main \
  || fail "P4: prefix record did not merge"

# P5: bad shas are rejected before any write; unknown full shas only warn.
set +e
factory-gate-grok record "../evil" success x >"$FIX/record-p5-bad.log" 2>&1
RC=$?
set -e
[[ "$RC" -ne 0 ]] || fail "P5: malicious sha was accepted"
[[ -z "$(find "$FIX" -maxdepth 3 -name 'evil*' -print -quit)" ]] \
  || fail "P5: malicious sha wrote a file"
UNKNOWN_SHA=0123456789abcdef0123456789abcdef01234567
set +e
factory-gate-grok record "$UNKNOWN_SHA" success x \
  >"$FIX/record-p5-unknown.out" 2>"$FIX/record-p5-unknown.err"
RC=$?
set -e
[[ "$RC" == 0 ]] || fail "P5: unknown sha exited $RC (want 0)"
grep -q "WARN no pending record for $UNKNOWN_SHA; nothing will continue" \
  "$FIX/record-p5-unknown.err" || fail "P5: no WARN for unknown sha"

# P6: a later success overrides a rejected marker and merges.
SHA_P6=$(new_branch p6)
gate_pending p6 "$SHA_P6"
BEFORE=$(origin_main)
factory-gate-grok record "$SHA_P6" failure "first pass rejected" >"$FIX/record-p6-fail.log" 2>&1 \
  || fail "P6: record failure exited non-zero"
[[ -f "$(marker "$SHA_P6")" ]] || fail "P6: no marker after failure"
[[ "$(marker_outcome "$SHA_P6")" == "rejected" ]] || fail "P6: marker outcome is not rejected"
[[ "$(origin_main)" == "$BEFORE" ]] || fail "P6: rejection moved origin main"
status_ok "$SHA_P6" guard
status_ok "$SHA_P6" ci
status_ok "$SHA_P6" "gate/claude"
factory-gate-grok record "$SHA_P6" success ok >"$FIX/record-p6-pass.log" 2>&1 \
  || fail "P6: record success after rejection exited non-zero"
[[ "$(marker_outcome "$SHA_P6")" == "merged" ]] || fail "P6: marker outcome is not merged"
git --git-dir="$FIX/origin.git" merge-base --is-ancestor "$SHA_P6" refs/heads/main \
  || fail "P6: later success did not merge"

# P7: a branch that moved after the verdict is stale, not merged.
SHA_P7=$(new_branch p7)
gate_pending p7 "$SHA_P7"
status_ok "$SHA_P7" guard
status_ok "$SHA_P7" ci
status_ok "$SHA_P7" "gate/claude"
printf 'extra after pending\n' >> "$WORK/README.md"
git -C "$WORK" add README.md
git -C "$WORK" commit -q -m "extra commit after pending"
BEFORE=$(origin_main)
factory-gate-grok record "$SHA_P7" success ok >"$FIX/record-p7.log" 2>&1 \
  || fail "P7: record success exited non-zero"
has_notify continue-stale || fail "P7: no continue-stale notification"
[[ "$(origin_main)" == "$BEFORE" ]] || fail "P7: stale record moved origin main"

echo "OK grok park"
