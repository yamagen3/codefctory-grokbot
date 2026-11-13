#!/usr/bin/env bash
# factory-queue: atomic pending entries, duplicate/state guards, remove rules,
# provider parking, and one-entry-per-call run-next. Offline: all runs are stubs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d /tmp/factory-queue-XXXXXX)"
trap 'rm -rf "$T"' EXIT
fail() { echo "test_factory_queue: FAIL $*" >&2; exit 1; }

unset FACTORY_QUEUE_DIR FACTORY_RUNS_DIR FACTORY_PROVIDER_STATE_DIR \
  FACTORY_GROK_MODE FACTORY_GROK_STUB FACTORY_TARGET_NAME FACTORY_LOG_DIR \
  FACTORY_QUEUE_RUN_CMD FACTORY_QUEUE_PROVIDER_CMD \
  FACTORY_QUEUE_PROVIDER_CHECK_CMD FACTORY_QUEUE_PREFLIGHT_CMD \
  FACTORY_QUEUE_SERIAL_TARGET || true
export FACTORY_ROOT="$ROOT"
export FACTORY_QUEUE_DIR="$T/queue"
export FACTORY_RUNS_DIR="$T/runs"
export FACTORY_PROVIDER_STATE_DIR="$T/providers"
export FACTORY_LOG_DIR="$T/logs"

Q="$ROOT/bin/factory-queue"
PS="$ROOT/bin/factory-provider-state"
PENDING="$FACTORY_QUEUE_DIR/pending"
STARTED="$FACTORY_QUEUE_DIR/started"
RUN_LOG="$T/run.calls"

cat > "$T/run-stub" <<'SH'
#!/usr/bin/env bash
set -u
if [[ -n "${STUB_RUN_NOISE:-}" ]]; then
  printf 'run-stdout-%s\n' "${1-}"
  printf 'run-stderr-%s\n' "${1-}" >&2
fi
{
  printf 'id=%s\n' "${1-}"
  printf 'brief=%s\n' "${2-}"
  printf 'target=%s\n' "${FACTORY_TARGET_NAME-}"
  printf 'grok_mode=%s\n' "${FACTORY_GROK_MODE-<unset>}"
  printf 'grok_stub=%s\n' "${FACTORY_GROK_STUB-<unset>}"
} >> "${STUB_RUN_LOG:?}"
exit "${STUB_RUN_RC:-0}"
SH
chmod +x "$T/run-stub"
export FACTORY_QUEUE_RUN_CMD="$T/run-stub"
export STUB_RUN_LOG="$RUN_LOG"

PASS_PREFLIGHT="$T/preflight-pass"
FAIL_PREFLIGHT="$T/preflight-fail"
cat > "$PASS_PREFLIGHT" <<'SH'
#!/usr/bin/env bash
echo ok
SH
cat > "$FAIL_PREFLIGHT" <<'SH'
#!/usr/bin/env bash
echo 'brain.model: stale profile'
echo 'profile detail on stderr' >&2
exit 1
SH
chmod +x "$PASS_PREFLIGHT" "$FAIL_PREFLIGHT"
export FACTORY_QUEUE_PREFLIGHT_CMD="$PASS_PREFLIGHT"

echo "=== (a) add writes one pending entry and list --json shows grok_mode=pending ==="
printf 'brief from file' > "$T/brief-a"
"$Q" add a1 --target target-a --brief-file "$T/brief-a"
[[ "$("$Q" count)" == "1" ]] || fail "(a) count is not 1"
JSON=$("$Q" list --json)
python3 - "$JSON" <<'PY'
import json
import sys

items = json.loads(sys.argv[1])
assert len(items) == 1, items
entry = items[0]
want = {"schema", "id", "kind", "target", "brief", "grok_mode", "grok_stub", "queued_at"}
assert set(entry) == want, entry
assert entry["schema"] == 1, entry
assert entry["id"] == "a1", entry
assert entry["kind"] == "code-cli", entry
assert entry["target"] == "target-a", entry
assert entry["brief"] == "brief from file", entry
assert entry["grok_mode"] == "pending", entry
assert entry["grok_stub"] is None, entry
assert isinstance(entry["queued_at"], str) and entry["queued_at"].endswith("Z"), entry
PY
shopt -s nullglob
files=("$PENDING"/*.json)
shopt -u nullglob
[[ "${#files[@]}" -eq 1 ]] || fail "(a) pending file count ${#files[@]}"
[[ "$(basename "${files[0]}")" =~ ^[0-9]{8}T[0-9]{6}Z-a1\.json$ ]] \
  || fail "(a) filename is $(basename "${files[0]}")"
[[ "$("$Q" list)" == *$'a1\ttarget-a\t'* ]] || fail "(a) text list did not show a1"

echo "=== (b) duplicate add exits 1 and keeps the first entry ==="
set +e
DUP_OUT=$("$Q" add a1 --target target-other -- 'other brief' 2>"$T/dup.err")
DUP_RC=$?
set -e
[[ "$DUP_RC" -eq 1 ]] || fail "(b) duplicate add exit $DUP_RC, want 1"
[[ -z "$DUP_OUT" ]] || fail "(b) duplicate add printed stdout: $DUP_OUT"
grep -qi 'already' "$T/dup.err" || fail "(b) duplicate message: $(cat "$T/dup.err")"
[[ "$("$Q" count)" == "1" ]] || fail "(b) duplicate changed the queue"

echo "=== (c) add refuses an id that already has a run state.json ==="
mkdir -p "$FACTORY_RUNS_DIR/c1"
printf '{}\n' > "$FACTORY_RUNS_DIR/c1/state.json"
set +e
"$Q" add c1 --target target-c -- 'state brief' >"$T/c1.out" 2>"$T/c1.err"
C1_RC=$?
set -e
[[ "$C1_RC" -eq 1 ]] || fail "(c) state add exit $C1_RC, want 1"
grep -qi 'state.json' "$T/c1.err" || fail "(c) state message: $(cat "$T/c1.err")"
shopt -s nullglob
c1_files=("$PENDING"/*-c1.json)
shopt -u nullglob
[[ "${#c1_files[@]}" -eq 0 ]] || fail "(c) refused entry was written"

echo "=== (d) run-next starts one entry with id, brief, target, and grok_mode=pending ==="
"$Q" remove a1
"$Q" add d1 --target target-d -- the d brief
rm -f "$RUN_LOG"
set +e
D_OUT=$(FACTORY_GROK_MODE=stale FACTORY_GROK_STUB=pass "$Q" run-next)
D_RC=$?
set -e
[[ "$D_RC" -eq 0 ]] || fail "(d) run-next exit $D_RC, want 0"
[[ "$D_OUT" == "started d1 exit=0" ]] || fail "(d) run-next output: $D_OUT"
python3 - "$RUN_LOG" <<'PY'
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    fields = dict(line.rstrip("\n").split("=", 1) for line in fh if "=" in line)
assert fields == {
    "id": "d1",
    "brief": "the d brief",
    "target": "target-d",
    "grok_mode": "pending",
    "grok_stub": "<unset>",
}, fields
PY
shopt -s nullglob
d_started=("$STARTED"/*-d1.json)
d_pending=("$PENDING"/*-d1.json)
shopt -u nullglob
[[ "${#d_started[@]}" -eq 1 ]] || fail "(d) d1 is not in started/"
[[ "${#d_pending[@]}" -eq 0 ]] || fail "(d) d1 is still pending"
[[ "$("$Q" count)" == "0" ]] || fail "(d) count after start is not 0"

echo "=== (e) provider-limited run-next exits 75, leaves pending, and does not run ==="
"$Q" add e1 --target target-e -- 'limited brief'
"$PS" mark claude-code $(( $(date +%s) + 3600 )) test-limit
rm -f "$RUN_LOG"
set +e
E_OUT=$("$Q" run-next)
E_RC=$?
set -e
[[ "$E_RC" -eq 75 ]] || fail "(e) run-next exit $E_RC, want 75"
[[ "$E_OUT" == limited\ * ]] || fail "(e) provider line: $E_OUT"
shopt -s nullglob
e_pending=("$PENDING"/*-e1.json)
e_started=("$STARTED"/*-e1.json)
shopt -u nullglob
[[ "${#e_pending[@]}" -eq 1 ]] || fail "(e) limited entry left pending/"
[[ "${#e_started[@]}" -eq 0 ]] || fail "(e) limited entry moved to started/"
[[ ! -e "$RUN_LOG" ]] || fail "(e) run stub was called while limited"
"$PS" clear claude-code
"$Q" remove e1

echo "=== (f) two entries start oldest first, one per run-next call ==="
"$Q" add f-old --target target-old -- 'old brief'
"$Q" add f-new --target target-new -- 'new brief'
rm -f "$RUN_LOG"
set +e
F1_OUT=$("$Q" run-next)
F1_RC=$?
F2_OUT=$("$Q" run-next)
F2_RC=$?
set -e
[[ "$F1_RC" -eq 0 && "$F2_RC" -eq 0 ]] || fail "(f) exits $F1_RC/$F2_RC"
[[ "$F1_OUT" == "started f-old exit=0" ]] || fail "(f) first started: $F1_OUT"
[[ "$F2_OUT" == "started f-new exit=0" ]] || fail "(f) second started: $F2_OUT"
IDS=$(sed -n 's/^id=//p' "$RUN_LOG")
[[ "$IDS" == $'f-old\nf-new' ]] || fail "(f) run order: $IDS"

echo "=== (g) remove deletes pending entries and refuses started ones ==="
"$Q" add g-started --target target-g -- 'started brief'
"$Q" run-next >/dev/null
set +e
"$Q" remove g-started >"$T/g-started.out" 2>"$T/g-started.err"
G_STARTED_RC=$?
set -e
[[ "$G_STARTED_RC" -eq 1 ]] || fail "(g) removing started exit $G_STARTED_RC, want 1"
shopt -s nullglob
g_started=("$STARTED"/*-g-started.json)
shopt -u nullglob
[[ "${#g_started[@]}" -eq 1 ]] || fail "(g) started entry was removed"

"$Q" add g-pending --target target-g -- 'pending brief'
"$Q" remove g-pending
shopt -s nullglob
g_pending=("$PENDING"/*-g-pending.json)
shopt -u nullglob
[[ "${#g_pending[@]}" -eq 0 ]] || fail "(g) pending entry was not removed"
set +e
"$Q" remove no-such-id >/dev/null 2>&1
G_MISSING_RC=$?
set -e
[[ "$G_MISSING_RC" -eq 1 ]] || fail "(g) missing remove exit $G_MISSING_RC, want 1"

# ---- R8: preflight, serial targets, kept output, status.json ----

assert_queue_status() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import json
import sys

path, label, pending, blocked, last_id, last_exit = sys.argv[1:]
with open(path, encoding="utf-8") as fh:
    doc = json.load(fh)
assert set(doc) == {"time", "pending", "blocked", "last"}, (label, doc)
assert isinstance(doc["time"], str) and doc["time"], (label, doc)
assert isinstance(doc["pending"], int) and not isinstance(doc["pending"], bool), (label, doc)
assert doc["pending"] == int(pending), (label, doc)
want_blocked = None if blocked == "<null>" else blocked
assert doc["blocked"] == want_blocked, (label, doc)
if last_id == "<null>":
    assert doc["last"] is None, (label, doc)
else:
    assert doc["last"] == {"id": last_id, "exit": int(last_exit)}, (label, doc)
PY
}

write_busy_state() {
  local run_id="$1" target="$2" exit_value="$3"
  mkdir -p "$FACTORY_RUNS_DIR/$run_id"
  printf '{"id":"%s","target":"%s","exit":%s}\n' \
    "$run_id" "$target" "$exit_value" > "$FACTORY_RUNS_DIR/$run_id/state.json"
}

use_r8_queue() {
  local name="$1"
  export FACTORY_QUEUE_DIR="$T/r8-$name-queue"
  export FACTORY_RUNS_DIR="$T/r8-$name-runs"
  export FACTORY_LOG_DIR="$T/r8-$name-logs"
  export FACTORY_QUEUE_PREFLIGHT_CMD="$PASS_PREFLIGHT"
  unset FACTORY_QUEUE_SERIAL_TARGET || true
  rm -rf "$FACTORY_QUEUE_DIR" "$FACTORY_RUNS_DIR" "$FACTORY_LOG_DIR"
  mkdir -p "$FACTORY_QUEUE_DIR" "$FACTORY_RUNS_DIR" "$FACTORY_LOG_DIR"
  PENDING="$FACTORY_QUEUE_DIR/pending"
  STARTED="$FACTORY_QUEUE_DIR/started"
}

set_entry_kind() {
  local run_id="$1" kind="$2"
  python3 - "$PENDING" "$run_id" "$kind" <<'PY'
import json
import os
import sys
from pathlib import Path

directory, run_id, kind = sys.argv[1:]
for path in sorted(Path(directory).glob("*.json")):
    doc = json.loads(path.read_text(encoding="utf-8"))
    if str(doc.get("id")) == run_id or path.stem.endswith("-" + run_id):
        stat = path.stat()
        doc["kind"] = kind
        path.write_text(json.dumps(doc, sort_keys=True) + "\n", encoding="utf-8")
        # Editing the kind must not make the entry look newer to run-next.
        os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        raise SystemExit(0)
raise SystemExit("entry not found: " + run_id)
PY
}

"$PS" clear claude-code >/dev/null 2>&1 || true

echo "=== (R8-a) add rejects an invalid target ==="
use_r8_queue target-invalid
rm -f "$RUN_LOG"
set +e
"$Q" add bad-target --target ../x -- 'bad target brief' >"$T/r8a.out" 2>"$T/r8a.err"
R8A_RC=$?
set -e
[[ "$R8A_RC" -eq 1 ]] || fail "(R8-a) invalid target exit $R8A_RC, want 1"
[[ "$("$Q" count)" == "0" ]] || fail "(R8-a) invalid target was queued"

echo "=== (R8-b) failing preflight blocks, leaves entries pending, and records it ==="
use_r8_queue preflight-fail
"$Q" add b-old --target t -- 'old brief'
"$Q" add b-new --target u -- 'new brief'
rm -f "$RUN_LOG"
set +e
R8B_OUT=$(FACTORY_QUEUE_PREFLIGHT_CMD="$FAIL_PREFLIGHT" "$Q" run-next 2>"$T/r8b.err")
R8B_RC=$?
set -e
[[ "$R8B_RC" -eq 1 ]] || fail "(R8-b) exit $R8B_RC, want 1"
[[ "$R8B_OUT" == "blocked profile-check" ]] || fail "(R8-b) stdout: $R8B_OUT"
grep -Fq 'brain.model: stale profile' "$T/r8b.err" \
  || fail "(R8-b) missing tool stdout on stderr: $(cat "$T/r8b.err")"
grep -Fq 'profile detail on stderr' "$T/r8b.err" \
  || fail "(R8-b) missing tool stderr: $(cat "$T/r8b.err")"
[[ ! -e "$RUN_LOG" ]] || fail "(R8-b) run stub was called"
[[ "$("$Q" count)" == "2" ]] || fail "(R8-b) pending count is not 2"
assert_queue_status "$FACTORY_QUEUE_DIR/status.json" "(R8-b)" 2 profile-check '<null>' '<null>'

echo "=== (R8-c) a later passing preflight starts the oldest entry ==="
set +e
R8C_OUT=$("$Q" run-next 2>"$T/r8c.err")
R8C_RC=$?
set -e
[[ "$R8C_RC" -eq 0 ]] || fail "(R8-c) exit $R8C_RC, want 0"
[[ "$R8C_OUT" == "started b-old exit=0" ]] || fail "(R8-c) stdout: $R8C_OUT"
[[ "$("$Q" count)" == "1" ]] || fail "(R8-c) pending count is not 1"
assert_queue_status "$FACTORY_QUEUE_DIR/status.json" "(R8-c)" 1 '<null>' b-old 0

echo "=== (R8-d) a target at exit 2 is deferred while another target starts ==="
use_r8_queue busy-exit2
write_busy_state busy-t t 2
"$Q" add d-t --target t -- 'older t brief'
"$Q" add d-u --target u -- 'newer u brief'
rm -f "$RUN_LOG"
R8D_OUT=$("$Q" run-next)
R8D_WANT=$'deferred d-t target-busy=busy-t\nstarted d-u exit=0'
[[ "$R8D_OUT" == "$R8D_WANT" ]] || fail "(R8-d) stdout: $R8D_OUT"
[[ "$(sed -n 's/^id=//p' "$RUN_LOG")" == "d-u" ]] || fail "(R8-d) run stub got the wrong entry"
shopt -s nullglob
r8d_t=("$PENDING"/*-d-t.json)
r8d_u=("$STARTED"/*-d-u.json)
shopt -u nullglob
[[ "${#r8d_t[@]}" -eq 1 ]] || fail "(R8-d) d-t did not stay pending"
[[ "${#r8d_u[@]}" -eq 1 ]] || fail "(R8-d) d-u did not start"
assert_queue_status "$FACTORY_QUEUE_DIR/status.json" "(R8-d)" 1 '<null>' d-u 0

echo "=== (R8-e) exit 75 and exit null also defer the target ==="
for R8E_CASE in 75 null; do
  use_r8_queue "busy-$R8E_CASE"
  write_busy_state "busy-$R8E_CASE" t "$R8E_CASE"
  "$Q" add "e$R8E_CASE-t" --target t -- 'older t brief'
  "$Q" add "e$R8E_CASE-u" --target u -- 'newer u brief'
  rm -f "$RUN_LOG"
  R8E_OUT=$("$Q" run-next)
  R8E_WANT=$(printf 'deferred e%s-t target-busy=busy-%s\nstarted e%s-u exit=0' \
    "$R8E_CASE" "$R8E_CASE" "$R8E_CASE")
  [[ "$R8E_OUT" == "$R8E_WANT" ]] \
    || fail "(R8-e $R8E_CASE) stdout: $R8E_OUT"
  [[ "$(sed -n 's/^id=//p' "$RUN_LOG")" == "e$R8E_CASE-u" ]] \
    || fail "(R8-e $R8E_CASE) run stub got the wrong entry"
  assert_queue_status "$FACTORY_QUEUE_DIR/status.json" \
    "(R8-e $R8E_CASE)" 1 '<null>' "e$R8E_CASE-u" 0
done

echo "=== (R8-f) exit 0 or 1 on the target does not defer ==="
for R8F_EXIT in 0 1; do
  use_r8_queue "target-exit-$R8F_EXIT"
  write_busy_state "busy-$R8F_EXIT" t "$R8F_EXIT"
  "$Q" add "f$R8F_EXIT-t" --target t -- 'brief'
  rm -f "$RUN_LOG"
  R8F_OUT=$("$Q" run-next)
  [[ "$R8F_OUT" == "started f$R8F_EXIT-t exit=0" ]] \
    || fail "(R8-f $R8F_EXIT) stdout: $R8F_OUT"
  [[ "$("$Q" count)" == "0" ]] || fail "(R8-f $R8F_EXIT) entry stayed pending"
  assert_queue_status "$FACTORY_QUEUE_DIR/status.json" \
    "(R8-f $R8F_EXIT)" 0 '<null>' "f$R8F_EXIT-t" 0
done

echo "=== (R8-g) FACTORY_QUEUE_SERIAL_TARGET=0 starts the oldest entry regardless ==="
use_r8_queue serial-off
write_busy_state busy-g t 2
"$Q" add g-t --target t -- 'older t brief'
"$Q" add g-u --target u -- 'newer u brief'
rm -f "$RUN_LOG"
R8G_OUT=$(FACTORY_QUEUE_SERIAL_TARGET=0 "$Q" run-next)
[[ "$R8G_OUT" == "started g-t exit=0" ]] || fail "(R8-g) stdout: $R8G_OUT"
[[ "$R8G_OUT" != *deferred* ]] || fail "(R8-g) entry was deferred"
[[ "$(sed -n 's/^id=//p' "$RUN_LOG")" == "g-t" ]] || fail "(R8-g) run stub got the wrong entry"
assert_queue_status "$FACTORY_QUEUE_DIR/status.json" "(R8-g)" 1 '<null>' g-t 0

echo "=== (R8-h) a non-code-cli entry stays pending and the next entry starts ==="
use_r8_queue kind-video
"$Q" add h-1-video --target t -- 'video brief'
"$Q" add h-2-code --target u -- 'code brief'
set_entry_kind h-1-video video
rm -f "$RUN_LOG"
set +e
R8H_OUT=$("$Q" run-next 2>"$T/r8h.err")
R8H_RC=$?
set -e
[[ "$R8H_RC" -eq 0 ]] || fail "(R8-h) exit $R8H_RC, want 0"
[[ "$R8H_OUT" == "started h-2-code exit=0" ]] || fail "(R8-h) stdout: $R8H_OUT"
grep -Fq 'not code-cli' "$T/r8h.err" || fail "(R8-h) missing warning: $(cat "$T/r8h.err")"
shopt -s nullglob
r8h_video=("$PENDING"/*-h-1-video.json)
r8h_code=("$STARTED"/*-h-2-code.json)
shopt -u nullglob
[[ "${#r8h_video[@]}" -eq 1 ]] || fail "(R8-h) video entry did not stay pending"
[[ "${#r8h_code[@]}" -eq 1 ]] || fail "(R8-h) code entry did not start"
assert_queue_status "$FACTORY_QUEUE_DIR/status.json" "(R8-h)" 1 '<null>' h-2-code 0

echo "=== (R8-i) run stdout/stderr are appended to queue-<id>.log ==="
use_r8_queue output-log
"$Q" add i-log --target t -- 'log brief'
LOG="$FACTORY_LOG_DIR/queue-i-log.log"
printf 'before run\n' > "$LOG"
rm -f "$RUN_LOG"
set +e
R8I_OUT=$(STUB_RUN_NOISE=1 "$Q" run-next 2>"$T/r8i.err")
R8I_RC=$?
set -e
[[ "$R8I_RC" -eq 0 ]] || fail "(R8-i) exit $R8I_RC, want 0"
[[ "$R8I_OUT" == "started i-log exit=0" ]] || fail "(R8-i) stdout: $R8I_OUT"
[[ -f "$LOG" ]] || fail "(R8-i) missing $LOG"
grep -Fqx 'before run' "$LOG" || fail "(R8-i) existing log content was lost"
grep -Fqx 'run-stdout-i-log' "$LOG" || fail "(R8-i) missing run stdout in log"
grep -Fqx 'run-stderr-i-log' "$LOG" || fail "(R8-i) missing run stderr in log"
[[ ! -s "$T/r8i.err" ]] || fail "(R8-i) run output leaked to stderr: $(cat "$T/r8i.err")"
assert_queue_status "$FACTORY_QUEUE_DIR/status.json" "(R8-i)" 0 '<null>' i-log 0

echo "=== (R8-j) status last records {id, exit} and is carried over ==="
use_r8_queue status-last
"$Q" add j-one --target t -- 'last brief'
rm -f "$RUN_LOG"
set +e
R8J_OUT=$(STUB_RUN_RC=7 "$Q" run-next)
R8J_RC=$?
set -e
[[ "$R8J_RC" -eq 0 ]] || fail "(R8-j) exit $R8J_RC, want 0"
[[ "$R8J_OUT" == "started j-one exit=7" ]] || fail "(R8-j) stdout: $R8J_OUT"
assert_queue_status "$FACTORY_QUEUE_DIR/status.json" "(R8-j start)" 0 '<null>' j-one 7
set +e
R8J2_OUT=$("$Q" run-next)
R8J2_RC=$?
set -e
[[ "$R8J2_RC" -eq 0 ]] || fail "(R8-j carry) exit $R8J2_RC, want 0"
[[ -z "$R8J2_OUT" ]] || fail "(R8-j carry) stdout: $R8J2_OUT"
assert_queue_status "$FACTORY_QUEUE_DIR/status.json" "(R8-j carry)" 0 '<null>' j-one 7

echo "test_factory_queue: PASS"
