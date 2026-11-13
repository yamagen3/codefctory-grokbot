#!/usr/bin/env bash
# factory-inbox: pending verdicts, notifications, provider limits, parked runs,
# counts, and acknowledgements.
# Offline; all state lives in temporary directories selected through env vars.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="$ROOT/bin:$PATH"
export FACTORY_ROOT="$ROOT"
FIX="$(mktemp -d /tmp/factory-inbox-XXXXXX)"
trap 'rm -rf "$FIX"' EXIT

fail() { echo "test_factory_inbox: FAIL $*" >&2; exit 1; }

export FACTORY_GROK_HOOK_DIR="$FIX/hooks"
export FACTORY_NOTIFY_DIR="$FIX/notify"
export FACTORY_PROVIDER_STATE_DIR="$FIX/providers"
export FACTORY_RUNS_DIR="$FIX/runs"
unset FACTORY_AGMSG_TEAM FACTORY_GROK_MODE FACTORY_GROK_STUB

check_rc() {
  local want="$1"
  shift
  local out rc
  set +e
  out=$("$@")
  rc=$?
  set -e
  [[ "$rc" == "$want" ]] || fail "$* exited $rc (want $want)"
  printf '%s\n' "$out"
}

write_pending() {
  local id="$1" sha="$2" mode="$3"
  cat > "$FACTORY_GROK_HOOK_DIR/pending-$sha.json" <<EOF
{
  "id": "$id",
  "sha": "$sha",
  "bundle": "$FACTORY_GROK_HOOK_DIR/bundle-$sha",
  "mode": "$mode",
  "created_at": "2026-11-12T00:00:00+00:00"
}
EOF
}

# Missing directories are an empty inbox.
[[ "$(factory-inbox count)" == "0" ]] || fail "empty inbox count"
[[ "$(check_rc 0 factory-inbox check)" == "0" ]] || fail "empty inbox check output"
[[ "$(factory-inbox list --json)" == "[]" ]] || fail "empty inbox JSON"

mkdir -p "$FACTORY_GROK_HOOK_DIR" "$FACTORY_NOTIFY_DIR"

SHA_VERDICT=1111111111111111111111111111111111111111
write_pending t1 "$SHA_VERDICT" pending
JSON=$(factory-inbox list --json)
python3 - "$JSON" "$SHA_VERDICT" "$FACTORY_GROK_HOOK_DIR" <<'PY'
import json, sys
items = json.loads(sys.argv[1])
sha, hook = sys.argv[2], sys.argv[3]
assert len(items) == 1, items
item = items[0]
assert set(item) == {"id", "sha", "bundle", "age_sec", "action", "attention"}, item
assert item["id"] == "t1", item
assert item["sha"] == sha, item
assert item["bundle"] == f"{hook}/bundle-{sha}", item
assert isinstance(item["age_sec"], int) and item["age_sec"] >= 0, item
assert item["attention"] is True, item
assert item["action"] == f'factory-gate-grok record {sha} success|failure "<reason>"', item
PY
TEXT=$(factory-inbox list)
[[ "$(printf '%s\n' "$TEXT" | wc -l)" == "1" ]] || fail "text list is not one line"
[[ "$(printf '%s\n' "$TEXT" | awk -F '\t' '{print NF}')" == "5" ]] \
  || fail "text list is not five tab-separated fields"

# mode=wait is not an attention item.
SHA_WAIT=2222222222222222222222222222222222222222
write_pending t2 "$SHA_WAIT" wait
JSON=$(factory-inbox list --json)
python3 - "$JSON" "$SHA_VERDICT" "$SHA_WAIT" <<'PY'
import json, sys
items = json.loads(sys.argv[1])
assert len(items) == 1, items
assert items[0]["sha"] == sys.argv[2], items
assert all(item["sha"] != sys.argv[3] for item in items), items
PY
rm -f "$FACTORY_GROK_HOOK_DIR/pending-$SHA_WAIT.json"

# A result turns the pending verdict into continue-needed.
printf '{"sha":"%s","state":"success"}\n' "$SHA_VERDICT" \
  > "$FACTORY_GROK_HOOK_DIR/result-$SHA_VERDICT.json"
JSON=$(factory-inbox list --json)
python3 - "$JSON" "$SHA_VERDICT" <<'PY'
import json, sys
items = json.loads(sys.argv[1])
sha = sys.argv[2]
assert len(items) == 1, items
item = items[0]
assert set(item) == {"id", "sha", "bundle", "age_sec", "action", "attention"}, item
assert item["sha"] == sha, item
assert item["attention"] is True, item
assert item["action"] == f"factory-continue {sha}", item
PY

# The continuation marker removes it.
printf '{"outcome":"merged"}\n' > "$FACTORY_GROK_HOOK_DIR/continued-$SHA_VERDICT.json"
[[ "$(factory-inbox list --json)" == "[]" ]] || fail "continued item was not removed"

# Only attention kinds are listed by default; --all includes the rest.
factory-notify merge-failed x >/dev/null 2>&1
factory-notify merged y >/dev/null 2>&1
MERGE_FILE=$(basename "$(compgen -G "$FACTORY_NOTIFY_DIR/*-merge-failed.txt" | head -1)")
[[ -n "$MERGE_FILE" ]] || fail "factory-notify did not create merge-failed"

JSON=$(factory-inbox list --json)
python3 - "$JSON" "$MERGE_FILE" <<'PY'
import json, sys
items = json.loads(sys.argv[1])
assert len(items) == 1, items
item = items[0]
assert set(item) == {"kind", "time", "message", "file", "attention"}, item
assert item["kind"] == "merge-failed", item
assert item["time"], item
assert item["message"] == "x", item
assert item["file"] == sys.argv[2], item
assert item["attention"] is True, item
PY

JSON_ALL=$(factory-inbox list --json --all)
python3 - "$JSON_ALL" <<'PY'
import json, sys
items = json.loads(sys.argv[1])
assert len(items) == 2, items
by_kind = {item["kind"]: item for item in items}
assert set(by_kind) == {"merge-failed", "merged"}, items
assert by_kind["merge-failed"]["attention"] is True, items
assert by_kind["merged"]["attention"] is False, items
PY
OUT=$(check_rc 10 factory-inbox check)
[[ "$OUT" == "1" ]] || fail "check output after merge-failed: $OUT"
[[ "$(factory-inbox count)" == "1" ]] || fail "count after merge-failed"

# Ack clears the attention item; a second ack is a no-op.
: > "$FACTORY_NOTIFY_DIR/.acked"
factory-inbox ack "$MERGE_FILE"
[[ "$(check_rc 0 factory-inbox check)" == "0" ]] || fail "check after ack"
FIRST_ACK=$(cat "$FACTORY_NOTIFY_DIR/.acked")
factory-inbox ack "$MERGE_FILE"
SECOND_ACK=$(cat "$FACTORY_NOTIFY_DIR/.acked")
[[ "$FIRST_ACK" == "$SECOND_ACK" ]] || fail "second ack changed .acked"
[[ "$(grep -c -x -F "$MERGE_FILE" "$FACTORY_NOTIFY_DIR/.acked")" == "1" ]] \
  || fail "ack was not idempotent"
python3 - "$(factory-inbox list --json --all)" <<'PY'
import json, sys
items = json.loads(sys.argv[1])
assert len(items) == 2, items
by_kind = {item["kind"]: item for item in items}
assert set(by_kind) == {"merge-failed", "merged"}, items
assert by_kind["merge-failed"]["attention"] is False, items
assert by_kind["merged"]["attention"] is False, items
PY

# Bad basenames are rejected without touching .acked.
set +e
factory-inbox ack ../x >/dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "1" ]] || fail "ack ../x exited $RC (want 1)"
set +e
factory-inbox ack no-such-notification.txt >/dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "1" ]] || fail "ack missing file exited $RC (want 1)"
[[ "$(cat "$FACTORY_NOTIFY_DIR/.acked")" == "$FIRST_ACK" ]] \
  || fail "failed ack changed .acked"

# Corrupt pending JSON is skipped, not fatal.
printf '{not json\n' > "$FACTORY_GROK_HOOK_DIR/pending-zz.json"
ERR="$FIX/corrupt.err"
set +e
CORRUPT_JSON=$(factory-inbox list --json 2>"$ERR")
RC=$?
set -e
[[ "$RC" == "0" ]] || fail "corrupt pending list exited $RC (want 0)"
[[ "$CORRUPT_JSON" == "[]" ]] || fail "corrupt pending was listed: $CORRUPT_JSON"
grep -qi 'skip' "$ERR" || fail "corrupt pending produced no warning"
rm -f "$FACTORY_GROK_HOOK_DIR/pending-zz.json"

# --- Provider limits and parked runs ---------------------------------------
mkdir -p "$FACTORY_PROVIDER_STATE_DIR" "$FACTORY_RUNS_DIR"
NOW=$(date +%s)
FUTURE=$((NOW + 3600))
cat > "$FACTORY_PROVIDER_STATE_DIR/claude-code.json" <<EOF
{"provider":"claude-code","state":"limited","reset_epoch":$FUTURE,"reason":"usage_limit_reached"}
EOF
printf '{"provider":"grok","state":"limited","reset_epoch":%s,"reason":"expired"}\n' \
  "$((NOW - 60))" > "$FACTORY_PROVIDER_STATE_DIR/grok.json"

JSON=$(factory-inbox list --json 2>/dev/null)
python3 - "$JSON" "$FUTURE" <<'PY'
import datetime
import json
import sys

items = json.loads(sys.argv[1])
assert len(items) == 1, items
item = items[0]
assert set(item) == {
    "kind",
    "provider",
    "until",
    "resume_in_sec",
    "reason",
    "attention",
}, item
assert item["kind"] == "provider-limited", item
assert item["provider"] == "claude-code", item
assert item["reason"] == "usage_limit_reached", item
assert item["attention"] is False, item
assert isinstance(item["resume_in_sec"], int) and item["resume_in_sec"] > 0, item
until = datetime.datetime.fromisoformat(item["until"])
want = datetime.datetime.fromtimestamp(int(sys.argv[2]), datetime.timezone.utc)
assert abs(until.timestamp() - want.timestamp()) < 2, item
PY
[[ "$(factory-inbox count)" == "0" ]] || fail "provider limit counted as attention"
[[ "$(check_rc 0 factory-inbox check)" == "0" ]] || fail "provider limit check was not 0"
TEXT=$(factory-inbox list 2>/dev/null)
[[ "$(printf '%s\n' "$TEXT" | wc -l)" == "1" ]] || fail "provider text row count"
[[ "$(printf '%s\n' "$TEXT" | awk -F '\t' '{print NF}')" == "5" ]] \
  || fail "provider text row shape"

# A run parked at exit 75 is listed but not attention while the provider is limited.
RUN_ID=run-parked
RUN_SHA=3333333333333333333333333333333333333333
mkdir -p "$FACTORY_RUNS_DIR/$RUN_ID"
cat > "$FACTORY_RUNS_DIR/$RUN_ID/state.json" <<EOF
{"id":"$RUN_ID","exit":75,"stage":"impl","round":2,"sha":"$RUN_SHA"}
EOF
JSON=$(factory-inbox list --json 2>/dev/null)
python3 - "$JSON" "$RUN_ID" "$RUN_SHA" <<'PY'
import json
import sys

items = json.loads(sys.argv[1])
assert len(items) == 2, items
run = next(item for item in items if item["kind"] == "run-parked")
assert set(run) == {
    "kind",
    "id",
    "stage",
    "round",
    "sha",
    "action",
    "attention",
}, run
assert run["id"] == sys.argv[2], run
assert run["stage"] == "impl", run
assert run["round"] == 2, run
assert run["sha"] == sys.argv[3], run
assert run["action"] == "factory-resume", run
assert run["attention"] is False, run
assert any(item["kind"] == "provider-limited" for item in items), items
PY
[[ "$(factory-inbox count)" == "0" ]] || fail "parked run under provider limit counted"
[[ "$(check_rc 0 factory-inbox check)" == "0" ]] \
  || fail "parked run under provider limit check was not 0"

# Removing the provider limit makes the parked run an attention item.
rm -f "$FACTORY_PROVIDER_STATE_DIR/claude-code.json"
JSON=$(factory-inbox list --json 2>/dev/null)
python3 - "$JSON" "$RUN_ID" "$RUN_SHA" <<'PY'
import json
import sys

items = json.loads(sys.argv[1])
assert len(items) == 1, items
run = items[0]
assert set(run) == {
    "kind",
    "id",
    "stage",
    "round",
    "sha",
    "action",
    "attention",
}, run
assert run["kind"] == "run-parked", run
assert run["id"] == sys.argv[2], run
assert run["sha"] == sys.argv[3], run
assert run["action"] == "factory-resume", run
assert run["attention"] is True, run
PY
OUT=$(check_rc 10 factory-inbox check)
[[ "$OUT" == "1" ]] || fail "parked run check output: $OUT"
[[ "$(factory-inbox count)" == "1" ]] || fail "parked run count"
TEXT=$(factory-inbox list 2>/dev/null)
[[ "$(printf '%s\n' "$TEXT" | wc -l)" == "1" ]] || fail "parked text row count"
[[ "$(printf '%s\n' "$TEXT" | awk -F '\t' '{print NF}')" == "6" ]] \
  || fail "parked text row shape"

# A run that did not park (exit 0) is not listed.
mkdir -p "$FACTORY_RUNS_DIR/run-ok"
cat > "$FACTORY_RUNS_DIR/run-ok/state.json" <<EOF
{"id":"run-ok","exit":0,"stage":"merge","round":2,"sha":"$RUN_SHA"}
EOF
JSON=$(factory-inbox list --json 2>/dev/null)
python3 - "$JSON" "$RUN_ID" <<'PY'
import json
import sys

items = json.loads(sys.argv[1])
assert len(items) == 1, items
assert items[0]["id"] == sys.argv[2], items
PY

# Unparsable provider/run JSON is skipped with a warning and no content leak.
printf 'not json SECRET-PROVIDER\n' > "$FACTORY_PROVIDER_STATE_DIR/broken.json"
mkdir -p "$FACTORY_RUNS_DIR/run-broken"
printf 'not json SECRET-RUN\n' > "$FACTORY_RUNS_DIR/run-broken/state.json"
printf 'SECRET-OTHER-FILE\n' > "$FACTORY_PROVIDER_STATE_DIR/notes.txt"
ERR2="$FIX/new-corrupt.err"
set +e
JSON=$(factory-inbox list --json 2>"$ERR2")
RC=$?
set -e
[[ "$RC" == "0" ]] || fail "corrupt provider/run list exited $RC (want 0)"
python3 - "$JSON" "$RUN_ID" <<'PY'
import json
import sys

items = json.loads(sys.argv[1])
assert len(items) == 1, items
assert items[0]["id"] == sys.argv[2], items
PY
grep -qi 'skip' "$ERR2" || fail "corrupt provider/run produced no warning"
if grep -q 'SECRET-' "$ERR2"; then fail "corrupt provider/run leaked file content"; fi
if printf '%s' "$JSON" | grep -q 'SECRET-'; then fail "corrupt provider/run list leaked file content"; fi

# update-deferred-repeated is an attention notification kind.
factory-notify update-deferred-repeated z >/dev/null 2>&1
JSON=$(factory-inbox list --json 2>/dev/null)
python3 - "$JSON" <<'PY'
import json
import sys

items = json.loads(sys.argv[1])
updated = [item for item in items if item["kind"] == "update-deferred-repeated"]
assert len(updated) == 1, items
assert updated[0]["attention"] is True, updated[0]
PY

# A provider-limited notification is still formatted as a notification, not as a
# provider state item, when --all includes it in text mode.
factory-notify provider-limited "claude-code limited until 2026-11-13T00:00:00+00:00" >/dev/null 2>&1
factory-inbox list >/dev/null 2>&1 || fail "text list with provider-limited notification"
factory-inbox list --all >/dev/null 2>&1 || fail "text list --all with provider-limited notification"

echo "OK factory-inbox"
