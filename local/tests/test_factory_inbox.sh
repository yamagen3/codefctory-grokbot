#!/usr/bin/env bash
# factory-inbox: pending verdicts, notifications, counts, and acknowledgements.
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
assert set(item) == {"id", "sha", "bundle", "age_sec", "action"}, item
assert item["id"] == "t1", item
assert item["sha"] == sha, item
assert item["bundle"] == f"{hook}/bundle-{sha}", item
assert isinstance(item["age_sec"], int) and item["age_sec"] >= 0, item
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
assert set(item) == {"id", "sha", "bundle", "age_sec", "action"}, item
assert item["sha"] == sha, item
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
assert set(item) == {"kind", "time", "message", "file"}, item
assert item["kind"] == "merge-failed", item
assert item["time"], item
assert item["message"] == "x", item
assert item["file"] == sys.argv[2], item
PY

JSON_ALL=$(factory-inbox list --json --all)
python3 - "$JSON_ALL" <<'PY'
import json, sys
items = json.loads(sys.argv[1])
assert len(items) == 2, items
assert {item["kind"] for item in items} == {"merge-failed", "merged"}, items
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
assert {item["kind"] for item in items} == {"merge-failed", "merged"}, items
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

echo "OK factory-inbox"
