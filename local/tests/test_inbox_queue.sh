#!/usr/bin/env bash
# factory-inbox: queued entries, queue status, tick freshness, and parked runs.
# Offline; all state lives in temporary directories selected through env vars.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="$ROOT/bin:$PATH"
export FACTORY_ROOT="$ROOT"
T="$(mktemp -d /tmp/factory-inbox-queue-XXXXXX)"
trap 'rm -rf "$T"' EXIT

fail() { echo "test_inbox_queue: FAIL $*" >&2; exit 1; }

export FACTORY_GROK_HOOK_DIR="$T/hooks"
export FACTORY_NOTIFY_DIR="$T/notify"
export FACTORY_PROVIDER_STATE_DIR="$T/providers"
export FACTORY_RUNS_DIR="$T/runs"
export FACTORY_QUEUE_DIR="$T/queue"
export FACTORY_STATUS_DIR="$T/status"
unset FACTORY_INBOX_TICK_FRESH_SEC FACTORY_AGMSG_TEAM FACTORY_GROK_MODE \
  FACTORY_GROK_STUB || true

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

reset_state() {
  rm -rf "$FACTORY_QUEUE_DIR" "$FACTORY_STATUS_DIR" "$FACTORY_RUNS_DIR" \
    "$FACTORY_PROVIDER_STATE_DIR" "$FACTORY_GROK_HOOK_DIR" "$FACTORY_NOTIFY_DIR"
  mkdir -p "$FACTORY_GROK_HOOK_DIR" "$FACTORY_NOTIFY_DIR"
}

ago() {
  python3 - "$1" <<'PY'
import datetime
import sys

when = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(
    seconds=int(sys.argv[1])
)
print(when.isoformat(timespec="seconds").replace("+00:00", "Z"))
PY
}

write_queue_entry() {
  local id="$1" target="$2" queued_at="$3"
  mkdir -p "$FACTORY_QUEUE_DIR/pending"
  cat > "$FACTORY_QUEUE_DIR/pending/20261113T000000Z-$id.json" <<EOF
{"schema":1,"id":"$id","kind":"code-cli","target":"$target","brief":"brief $id","grok_mode":"pending","grok_stub":null,"queued_at":"$queued_at"}
EOF
}

write_tick() {
  local at="${1:-$(ago 0)}"
  mkdir -p "$FACTORY_STATUS_DIR"
  printf '{"time":"%s","resume_rc":0,"resumed":[],"started":[],"attention":0,"provider_limited":false}\n' \
    "$at" > "$FACTORY_STATUS_DIR/tick.json"
}

write_parked_run() {
  local id="$1" stage="$2" round="${3:-1}" sha="$4"
  mkdir -p "$FACTORY_RUNS_DIR/$id"
  cat > "$FACTORY_RUNS_DIR/$id/state.json" <<EOF
{"id":"$id","exit":75,"stage":"$stage","round":$round,"sha":"$sha"}
EOF
}

# --- (a) two pending entries and a fresh tick are reported, not counted ------
echo "=== (a) queued entries are listed with a fresh tick and check is 0 ==="
reset_state
write_queue_entry q1 target-one 2026-11-13T00:00:00Z
write_queue_entry q2 target-two 2026-11-13T00:01:00Z
write_tick
JSON=$(factory-inbox list --json)
python3 - "$JSON" <<'PY'
import json
import sys

items = json.loads(sys.argv[1])
assert len(items) == 2, items
by_id = {item["id"]: item for item in items}
assert set(by_id) == {"q1", "q2"}, items
for run_id, target in (("q1", "target-one"), ("q2", "target-two")):
    item = by_id[run_id]
    assert set(item) == {"kind", "id", "target", "queued_at", "attention"}, item
    assert item["kind"] == "queued", item
    assert item["target"] == target, item
    assert item["queued_at"].startswith("2026-11-13T00:0"), item
    assert item["attention"] is False, item
PY
[[ "$(check_rc 0 factory-inbox check)" == "0" ]] || fail "(a) check output"
TEXT=$(factory-inbox list)
[[ "$(printf '%s\n' "$TEXT" | wc -l)" == "2" ]] || fail "(a) text row count"
[[ "$(printf '%s\n' "$TEXT" | awk -F '\t' '{print NF}' | sort -u)" == "4" ]] \
  || fail "(a) queued text row shape"
[[ "$TEXT" == *$'queued\tq1\ttarget-one\t'* ]] || fail "(a) text list did not show q1"

# --- (b) no tick.json with queued work reports one tick-stale ----------------
echo "=== (b) a missing tick with queued work is tick-stale and check exits 10 ==="
rm -f "$FACTORY_STATUS_DIR/tick.json"
JSON=$(factory-inbox list --json)
python3 - "$JSON" <<'PY'
import json
import sys

items = json.loads(sys.argv[1])
assert len(items) == 3, items
queued = [item for item in items if item["kind"] == "queued"]
stale = [item for item in items if item["kind"] == "tick-stale"]
assert len(queued) == 2, items
assert len(stale) == 1, items
assert stale[0]["attention"] is True, stale
assert set(stale[0]) == {"kind", "message", "attention"}, stale
assert "never" in stale[0]["message"], stale
PY
OUT=$(check_rc 10 factory-inbox check)
[[ "$OUT" == "1" ]] || fail "(b) check output: $OUT"
TEXT=$(factory-inbox list)
[[ "$TEXT" == *$'tick-stale\tfactory tick is stale'* ]] \
  || fail "(b) text list did not show tick-stale"
[[ "$TEXT" == *never* ]] || fail "(b) stale message did not say never"

# --- (c) tick age follows FACTORY_INBOX_TICK_FRESH_SEC -----------------------
echo "=== (c) an old tick is stale, and the freshness limit is honoured ==="
write_tick "$(ago 120)"
JSON=$(factory-inbox list --json)
python3 - "$JSON" <<'PY'
import json
import sys

items = json.loads(sys.argv[1])
assert [item["kind"] for item in items] == ["queued", "queued"], items
assert all(item["attention"] is False for item in items), items
PY
[[ "$(check_rc 0 factory-inbox check)" == "0" ]] || fail "(c) default check"
TICK_TIME=$(python3 - "$FACTORY_STATUS_DIR/tick.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    print(json.load(fh)["time"])
PY
)
JSON=$(env FACTORY_INBOX_TICK_FRESH_SEC=60 factory-inbox list --json)
python3 - "$JSON" "$TICK_TIME" <<'PY'
import json
import sys

items = json.loads(sys.argv[1])
stale = [item for item in items if item["kind"] == "tick-stale"]
assert len(stale) == 1, items
assert sys.argv[2] in stale[0]["message"], stale
PY
OUT=$(check_rc 10 env FACTORY_INBOX_TICK_FRESH_SEC=60 factory-inbox check)
[[ "$OUT" == "1" ]] || fail "(c) custom-limit check output: $OUT"
JSON=$(env FACTORY_INBOX_TICK_FRESH_SEC=7200 factory-inbox list --json)
python3 - "$JSON" <<'PY'
import json
import sys

items = json.loads(sys.argv[1])
assert [item["kind"] for item in items] == ["queued", "queued"], items
PY
[[ "$(check_rc 0 env FACTORY_INBOX_TICK_FRESH_SEC=7200 factory-inbox check)" == "0" ]] \
  || fail "(c) raised-limit check"

# --- (d) a resumable parked run is quiet while the tick is fresh -------------
echo "=== (d) parked impl run with a fresh tick is not attention ==="
reset_state
write_tick
write_parked_run run-impl impl 2 3333333333333333333333333333333333333333
JSON=$(factory-inbox list --json)
python3 - "$JSON" <<'PY'
import json
import sys

items = json.loads(sys.argv[1])
assert len(items) == 1, items
run = items[0]
assert run["kind"] == "run-parked", run
assert run["stage"] == "impl", run
assert run["attention"] is False, run
PY
[[ "$(check_rc 0 factory-inbox check)" == "0" ]] || fail "(d) check output"

# --- (e) the same run with a stale tick needs attention ----------------------
echo "=== (e) parked impl run with a stale tick is attention plus tick-stale ==="
OLD_TICK=$(ago 7200)
write_tick "$OLD_TICK"
JSON=$(factory-inbox list --json)
python3 - "$JSON" "$OLD_TICK" <<'PY'
import json
import sys

items = json.loads(sys.argv[1])
runs = [item for item in items if item["kind"] == "run-parked"]
stale = [item for item in items if item["kind"] == "tick-stale"]
assert len(runs) == 1, items
assert runs[0]["attention"] is True, runs
assert len(stale) == 1, items
assert stale[0]["attention"] is True, stale
assert sys.argv[2] in stale[0]["message"], stale
PY
OUT=$(check_rc 10 factory-inbox check)
[[ "$OUT" == "2" ]] || fail "(e) check output: $OUT"

# --- (f) a non-resumable stage stays attention even with a fresh tick --------
echo "=== (f) parked ci run with a fresh tick is attention ==="
reset_state
write_tick
write_parked_run run-ci ci 1 4444444444444444444444444444444444444444
JSON=$(factory-inbox list --json)
python3 - "$JSON" <<'PY'
import json
import sys

items = json.loads(sys.argv[1])
assert len(items) == 1, items
run = items[0]
assert run["kind"] == "run-parked", run
assert run["stage"] == "ci", run
assert run["attention"] is True, run
PY
OUT=$(check_rc 10 factory-inbox check)
[[ "$OUT" == "1" ]] || fail "(f) check output: $OUT"

# --- (g) a blocked queue status is an attention item -------------------------
echo "=== (g) queue status blocked=profile-check is attention ==="
reset_state
mkdir -p "$FACTORY_QUEUE_DIR"
printf '{"blocked":"profile-check"}\n' > "$FACTORY_QUEUE_DIR/status.json"
JSON=$(factory-inbox list --json)
python3 - "$JSON" <<'PY'
import json
import sys

items = json.loads(sys.argv[1])
assert len(items) == 1, items
blocked = items[0]
assert blocked["kind"] == "queue-blocked", blocked
assert set(blocked) == {"kind", "message", "attention"}, blocked
assert "profile-check" in blocked["message"], blocked
assert blocked["attention"] is True, blocked
PY
OUT=$(check_rc 10 factory-inbox check)
[[ "$OUT" == "1" ]] || fail "(g) check output: $OUT"
TEXT=$(factory-inbox list)
[[ "$TEXT" == *$'queue-blocked\tqueue blocked: profile-check'* ]] \
  || fail "(g) text list did not show queue-blocked"

# A null blocked value is not an item.
printf '{"blocked":null}\n' > "$FACTORY_QUEUE_DIR/status.json"
[[ "$(factory-inbox list --json)" == "[]" ]] || fail "(g) null blocked was listed"

# --- (h) no queue directory and no parked runs is still an empty inbox -------
echo "=== (h) absent queue and runs keep the old empty output ==="
reset_state
rm -rf "$FACTORY_QUEUE_DIR"
[[ "$(factory-inbox list --json)" == "[]" ]] || fail "(h) empty JSON"
[[ -z "$(factory-inbox list)" ]] || fail "(h) empty text list"
[[ "$(factory-inbox count)" == "0" ]] || fail "(h) empty count"
[[ "$(check_rc 0 factory-inbox check)" == "0" ]] || fail "(h) empty check output"

echo "OK test_inbox_queue"
