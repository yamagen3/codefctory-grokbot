#!/usr/bin/env bash
# factory-continue: a Grok rejection requeues the parked run when its state matches.
# Fully offline: fake root, local git repo, stubs, no dsh/claude/opencode/gh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d /tmp/factory-continue-requeue-XXXXXX)"
trap 'rm -rf "$T"' EXIT

fail() { echo "test_continue_requeue: FAIL $*" >&2; exit 1; }

unset FACTORY_AGMSG_TEAM FACTORY_BACKEND FACTORY_GROK_STUB FACTORY_GROK_MODE \
  FACTORY_GROK_AUTO_CONTINUE FACTORY_GROK_REJECT_REQUEUE || true
export GIT_AUTHOR_NAME=factory GIT_AUTHOR_EMAIL=factory@localhost
export GIT_COMMITTER_NAME=factory GIT_COMMITTER_EMAIL=factory@localhost

# Fake root: real continue/feedback/notify, stubbed merge.
FAKE="$T/root"
mkdir -p "$FAKE/bin"
for f in factory-continue factory-common.sh factory-feedback factory-notify; do
  cp "$ROOT/bin/$f" "$FAKE/bin/$f"
  chmod +x "$FAKE/bin/$f"
done
cat > "$FAKE/bin/factory-merge" <<'SH'
#!/usr/bin/env bash
printf 'merge %s %s\n' "${1:-}" "${2:-}" >> "${MERGE_LOG:?}"
echo "merge stub"
exit 0
SH
chmod +x "$FAKE/bin/factory-merge"

export FACTORY_ROOT="$FAKE"
export FACTORY_STATUS_DIR="$T/status"
export FACTORY_LABELS_DIR="$T/labels"
export FACTORY_PR_DIR="$T/prs"
export FACTORY_GROK_HOOK_DIR="$T/hooks"
export FACTORY_RUNS_DIR="$T/runs"
export FACTORY_USAGE_DIR="$T/usage"
mkdir -p "$FACTORY_GROK_HOOK_DIR" "$FACTORY_RUNS_DIR"
export PATH="$FAKE/bin:$ROOT/bin:$PATH"

# Small git repo whose factory/<id> head is the reviewed sha.
git init -q -b main "$T/repo"
printf 'base\n' > "$T/repo/README.md"
git -C "$T/repo" add README.md
git -C "$T/repo" commit -q -m base

new_sha() {
  local id="$1"
  git -C "$T/repo" checkout -q main
  git -C "$T/repo" checkout -q -B "factory/$id"
  printf '%s\n' "$id" >> "$T/repo/README.md"
  git -C "$T/repo" add README.md
  git -C "$T/repo" commit -q -m "work $id"
  git -C "$T/repo" rev-parse HEAD
}

write_pending() {
  local id="$1" sha="$2" mode="${3:-pending}"
  python3 - "$FACTORY_GROK_HOOK_DIR/pending-$sha.json" "$sha" "$id" "$T/repo" "$mode" <<'PY'
import datetime, json, sys

path, sha, run_id, repo, mode = sys.argv[1:6]
doc = {
    "sha": sha,
    "id": run_id,
    "repo": repo,
    "bundle": f"/tmp/bundle-{sha}",
    "mode": mode,
    "status": "pending",
    "instruction": "factory-gate-grok record <sha> success|failure <reason>",
    "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
PY
}

write_result() {
  local sha="$1" state="$2" reason="$3"
  python3 - "$FACTORY_GROK_HOOK_DIR/result-$sha.json" "$sha" "$state" "$reason" <<'PY'
import datetime, json, sys

path, sha, state, reason = sys.argv[1:5]
doc = {
    "sha": sha,
    "state": state,
    "description": reason,
    "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "recorder": "grok",
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
PY
}

write_state() {
  local id="$1" sha="$2" round="$3" exit_code="$4" stage="$5"
  local dir="$FACTORY_RUNS_DIR/$id"
  mkdir -p "$dir"
  python3 - "$dir/state.json" "$id" "$sha" "$round" "$exit_code" "$stage" "$T/repo" <<'PY'
import json, sys

path, run_id, sha, round_raw, exit_raw, stage, work = sys.argv[1:8]
doc = {
    "id": run_id,
    "target": "t",
    "stage": stage,
    "round": int(round_raw),
    "sha": sha,
    "exit": int(exit_raw),
    "grok_mode": "pending",
    "grok_stub": None,
    "work": work,
    "max_rounds": 3,
    "updated_at": "2026-01-01T00:00:00+00:00",
    "note": "keep-me",
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, sort_keys=True)
    fh.write("\n")
PY
}

state_value() {
  python3 - "$1" "$2" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as fh:
    doc = json.load(fh)
value = doc.get(sys.argv[2])
print("" if value is None else value)
PY
}

assert_state() {
  local path="$1" key="$2" want="$3" got
  got="$(state_value "$path" "$key")"
  [[ "$got" == "$want" ]] || fail "state $key=$got, want $want ($path)"
}

marker() { echo "$FACTORY_GROK_HOOK_DIR/continued-$1.json"; }
marker_outcome() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("outcome",""))' "$(marker "$1")"
}
notify_has() { compgen -G "$1/*-$2.txt" >/dev/null; }
notify_count() {
  local files
  files="$(compgen -G "$1/*-$2.txt" || true)"
  if [[ -z "$files" ]]; then
    echo 0
  else
    printf '%s\n' "$files" | wc -l | tr -d ' '
  fi
}
notify_contains() {
  grep -q -- "$2" "$1"/*-"$3".txt 2>/dev/null
}

# (a) matching parked state: reject, write feedback, requeue, and do not page.
ID_A=a
SHA_A=$(new_sha "$ID_A")
write_pending "$ID_A" "$SHA_A"
write_result "$SHA_A" failure "missing --help"
write_state "$ID_A" "$SHA_A" 2 2 gate-grok
NA="$T/notify-a"
mkdir -p "$NA"
STATE_A="$FACTORY_RUNS_DIR/$ID_A/state.json"
set +e
FACTORY_NOTIFY_DIR="$NA" factory-continue "$SHA_A" >"$T/continue-a.log" 2>&1
RC=$?
set -e
[[ "$RC" == 4 ]] || fail "case a: exit $RC, want 4: $(cat "$T/continue-a.log")"
assert_state "$STATE_A" stage impl
assert_state "$STATE_A" round 3
assert_state "$STATE_A" exit 75
assert_state "$STATE_A" sha "$SHA_A"
assert_state "$STATE_A" id "$ID_A"
assert_state "$STATE_A" max_rounds 3
assert_state "$STATE_A" note keep-me
assert_state "$STATE_A" updated_at "2026-01-01T00:00:00+00:00"
FEEDBACK_A="$FACTORY_RUNS_DIR/$ID_A/feedback-r2.md"
[[ -f "$FEEDBACK_A" ]] || fail "case a: no feedback-r2.md"
grep -q -- "missing --help" "$FEEDBACK_A" || fail "case a: feedback lost the reason"
[[ ! -e "$FACTORY_RUNS_DIR/$ID_A/feedback-r3.md" ]] || fail "case a: feedback used the new round"
notify_has "$NA" grok-rejected-requeued || fail "case a: no grok-rejected-requeued notification"
notify_contains "$NA" "$ID_A" grok-rejected-requeued || fail "case a: requeue notification lost id"
notify_contains "$NA" "$SHA_A" grok-rejected-requeued || fail "case a: requeue notification lost sha"
notify_contains "$NA" "missing --help" grok-rejected-requeued || fail "case a: requeue notification lost reason"
notify_has "$NA" grok-rejected && fail "case a: paged with grok-rejected"
[[ -f "$(marker "$SHA_A")" ]] || fail "case a: no continued marker"
[[ "$(marker_outcome "$SHA_A")" == "rejected" ]] || fail "case a: marker outcome is not rejected"
grep -Fq "factory-continue: Grok rejected $SHA_A (missing --help)" "$T/continue-a.log" \
  || fail "case a: rejection stderr line changed"
compgen -G "$FACTORY_RUNS_DIR/$ID_A/.state.json.*" >/dev/null \
  && fail "case a: atomic state rewrite left a temp file"

# (e) a second call is idempotent.
cp "$STATE_A" "$T/state-a-before-second.json"
cp "$(marker "$SHA_A")" "$T/marker-a-before-second.json"
FEEDBACK_BEFORE="$(find "$FACTORY_RUNS_DIR/$ID_A" -maxdepth 1 -name 'feedback-r*.md' | wc -l | tr -d ' ')"
NOTIFY_BEFORE="$(find "$NA" -maxdepth 1 -name '*.txt' | wc -l | tr -d ' ')"
set +e
FACTORY_NOTIFY_DIR="$NA" factory-continue "$SHA_A" >"$T/continue-e.log" 2>&1
RC=$?
set -e
[[ "$RC" == 0 ]] || fail "case e: exit $RC, want 0: $(cat "$T/continue-e.log")"
grep -q "already continued" "$T/continue-e.log" || fail "case e: no already-continued line"
cmp -s "$STATE_A" "$T/state-a-before-second.json" || fail "case e: state changed"
cmp -s "$(marker "$SHA_A")" "$T/marker-a-before-second.json" || fail "case e: marker changed"
[[ "$(find "$FACTORY_RUNS_DIR/$ID_A" -maxdepth 1 -name 'feedback-r*.md' | wc -l | tr -d ' ')" == "$FEEDBACK_BEFORE" ]] \
  || fail "case e: feedback was rewritten"
[[ "$(find "$NA" -maxdepth 1 -name '*.txt' | wc -l | tr -d ' ')" == "$NOTIFY_BEFORE" ]] \
  || fail "case e: a notification was sent"

# (b) opt-out: state is untouched and the old grok-rejected page is sent.
ID_B=b
SHA_B=$(new_sha "$ID_B")
write_pending "$ID_B" "$SHA_B"
write_result "$SHA_B" failure "opt-out reason"
write_state "$ID_B" "$SHA_B" 4 2 gate-grok
NB="$T/notify-b"
mkdir -p "$NB"
STATE_B="$FACTORY_RUNS_DIR/$ID_B/state.json"
cp "$STATE_B" "$T/state-b-before.json"
set +e
FACTORY_NOTIFY_DIR="$NB" FACTORY_GROK_REJECT_REQUEUE=0 \
  factory-continue "$SHA_B" >"$T/continue-b.log" 2>&1
RC=$?
set -e
[[ "$RC" == 4 ]] || fail "case b: exit $RC, want 4: $(cat "$T/continue-b.log")"
cmp -s "$STATE_B" "$T/state-b-before.json" || fail "case b: state changed"
notify_has "$NB" grok-rejected || fail "case b: no grok-rejected notification"
notify_has "$NB" grok-rejected-requeued && fail "case b: requeued despite opt-out"
[[ ! -e "$FACTORY_RUNS_DIR/$ID_B/feedback-r4.md" ]] || fail "case b: wrote feedback despite opt-out"
[[ "$(marker_outcome "$SHA_B")" == "rejected" ]] || fail "case b: marker is not rejected"

# (c) no state.json: same as the old rejection path.
ID_C=c
SHA_C=$(new_sha "$ID_C")
write_pending "$ID_C" "$SHA_C"
write_result "$SHA_C" failure "no state reason"
rm -rf "$FACTORY_RUNS_DIR/$ID_C"
NC="$T/notify-c"
mkdir -p "$NC"
set +e
FACTORY_NOTIFY_DIR="$NC" factory-continue "$SHA_C" >"$T/continue-c.log" 2>&1
RC=$?
set -e
[[ "$RC" == 4 ]] || fail "case c: exit $RC, want 4: $(cat "$T/continue-c.log")"
[[ ! -e "$FACTORY_RUNS_DIR/$ID_C/state.json" ]] || fail "case c: state appeared"
notify_has "$NC" grok-rejected || fail "case c: no grok-rejected notification"
notify_has "$NC" grok-rejected-requeued && fail "case c: requeued without state"
[[ "$(marker_outcome "$SHA_C")" == "rejected" ]] || fail "case c: marker is not rejected"

# (d) state sha differs: same as the old rejection path.
ID_D=d
SHA_D=$(new_sha "$ID_D")
OTHER_SHA=$(new_sha d-other)
write_pending "$ID_D" "$SHA_D"
write_result "$SHA_D" failure "sha mismatch reason"
write_state "$ID_D" "$OTHER_SHA" 5 2 gate-grok
ND="$T/notify-d"
mkdir -p "$ND"
STATE_D="$FACTORY_RUNS_DIR/$ID_D/state.json"
cp "$STATE_D" "$T/state-d-before.json"
set +e
FACTORY_NOTIFY_DIR="$ND" factory-continue "$SHA_D" >"$T/continue-d.log" 2>&1
RC=$?
set -e
[[ "$RC" == 4 ]] || fail "case d: exit $RC, want 4: $(cat "$T/continue-d.log")"
cmp -s "$STATE_D" "$T/state-d-before.json" || fail "case d: mismatched state changed"
notify_has "$ND" grok-rejected || fail "case d: no grok-rejected notification"
notify_has "$ND" grok-rejected-requeued && fail "case d: requeued a mismatched sha"
[[ ! -e "$FACTORY_RUNS_DIR/$ID_D/feedback-r5.md" ]] || fail "case d: wrote feedback for a mismatch"
[[ "$(marker_outcome "$SHA_D")" == "rejected" ]] || fail "case d: marker is not rejected"

# (f) the success path still merges through factory-merge.
ID_F=f
SHA_F=$(new_sha "$ID_F")
write_pending "$ID_F" "$SHA_F"
write_result "$SHA_F" success ok
NF="$T/notify-f"
mkdir -p "$NF"
MERGE_LOG="$T/merge.log"
export MERGE_LOG
set +e
FACTORY_NOTIFY_DIR="$NF" factory-continue "$SHA_F" >"$T/continue-f.log" 2>&1
RC=$?
set -e
[[ "$RC" == 0 ]] || fail "case f: exit $RC, want 0: $(cat "$T/continue-f.log")"
[[ -f "$MERGE_LOG" ]] || fail "case f: factory-merge stub was not called"
grep -Fq "merge $T/repo $ID_F" "$MERGE_LOG" || fail "case f: merge stub got the wrong arguments"
[[ "$(marker_outcome "$SHA_F")" == "merged" ]] || fail "case f: marker is not merged"
notify_has "$NF" merged || fail "case f: no merged notification"
notify_has "$NF" grok-rejected && fail "case f: success path rejected"
notify_has "$NF" grok-rejected-requeued && fail "case f: success path requeued"

echo "OK continue requeue"
