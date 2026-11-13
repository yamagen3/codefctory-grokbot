#!/usr/bin/env bash
# factory-queue: atomic pending entries, duplicate/state guards, remove rules,
# provider parking, and one-entry-per-call run-next. Offline: all runs are stubs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d /tmp/factory-queue-XXXXXX)"
trap 'rm -rf "$T"' EXIT
fail() { echo "test_factory_queue: FAIL $*" >&2; exit 1; }

unset FACTORY_QUEUE_DIR FACTORY_RUNS_DIR FACTORY_PROVIDER_STATE_DIR \
  FACTORY_GROK_MODE FACTORY_GROK_STUB FACTORY_TARGET_NAME \
  FACTORY_QUEUE_RUN_CMD FACTORY_QUEUE_PROVIDER_CMD \
  FACTORY_QUEUE_PROVIDER_CHECK_CMD || true
export FACTORY_ROOT="$ROOT"
export FACTORY_QUEUE_DIR="$T/queue"
export FACTORY_RUNS_DIR="$T/runs"
export FACTORY_PROVIDER_STATE_DIR="$T/providers"

Q="$ROOT/bin/factory-queue"
PS="$ROOT/bin/factory-provider-state"
PENDING="$FACTORY_QUEUE_DIR/pending"
STARTED="$FACTORY_QUEUE_DIR/started"
RUN_LOG="$T/run.calls"

cat > "$T/run-stub" <<'SH'
#!/usr/bin/env bash
set -u
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

echo "test_factory_queue: PASS"
