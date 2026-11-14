#!/usr/bin/env bash
# Offline: gate/claude separates pass, fail, no verdict (75), and timeout (124).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d /tmp/factory-gate-claude-XXXXXX)"
trap 'rm -rf "$T"' EXIT

fail() { echo "test_gate_claude_verdict: FAIL $*" >&2; exit 1; }

REPO="$T/repo"
mkdir -p "$REPO/spec"
git -C "$REPO" init -q -b main
printf '# Product\n' > "$REPO/spec/PRODUCT.md"
git -C "$REPO" -c user.email=factory@localhost -c user.name=factory add spec/PRODUCT.md
git -C "$REPO" -c user.email=factory@localhost -c user.name=factory commit -qm "spec"
SHA="$(git -C "$REPO" rev-parse HEAD)"
ID=gate-verdict

FAKE_DSH="$T/fake-dsh"
cat > "$FAKE_DSH" <<'SH'
#!/usr/bin/env bash
stop="${FAKE_STOP:-}"
if [[ -z "$stop" ]]; then
  if [[ "${FAKE_EC:-0}" == "124" ]]; then stop=timeout; else stop=end_turn; fi
fi
if [[ "${FAKE_NOTHING:-0}" != "1" ]]; then
  python3 -c 'import json,sys; print(json.dumps({"stopReason": sys.argv[1], "text": sys.argv[2]}))' "$stop" "${FAKE_TEXT:-}"
  printf 'factory: step end stopReason=%s exit=%s\n' "$stop" "${FAKE_EC:-0}" >&2
fi
exit "${FAKE_EC:-0}"
SH
chmod +x "$FAKE_DSH"

STATUS_DIR="$T/status"
GATE_OUT="$T/gate.json"
GATE_GONE=/tmp/factory-gate-claude.json
if [[ -e "$GATE_GONE" ]]; then
  gate_gone_before="$(sha256sum "$GATE_GONE" | awk '{print $1}')"
else
  gate_gone_before="__absent__"
fi

status_field() {
  python3 - "$STATUS_DIR/$SHA.json" gate/claude "$1" <<'PY'
import json, sys

path, context, field = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    data = {}
value = data.get(context, {}).get(field)
print("" if value is None else value)
PY
}

run_gate() {
  local name="$1" want_ec="$2" want_state="$3" text="${4:-}" fake_ec="${5:-0}"
  local nothing="${6:-0}" stub="${7:-}" want_desc="${8:-}" ec got_state got_desc
  local -a stub_env=()
  [[ -n "$stub" ]] && stub_env+=("FACTORY_CLAUDE_GATE_STUB=$stub")

  rm -f "$GATE_OUT"
  set +e
  env -u FACTORY_CLAUDE_GATE_STUB -u FACTORY_GITHUB_TOKEN_CC \
    FACTORY_ROOT="$ROOT" \
    FACTORY_STEP_RUNNER="$FAKE_DSH" \
    FACTORY_USAGE_DISABLE=1 \
    FACTORY_STATUS_DIR="$STATUS_DIR" \
    FACTORY_GATE_CLAUDE_OUT="$GATE_OUT" \
    FAKE_TEXT="$text" \
    FAKE_EC="$fake_ec" \
    FAKE_NOTHING="$nothing" \
    "${stub_env[@]}" \
    "$ROOT/bin/factory-gate-claude" "$REPO" "$ID" "$SHA" >"$T/out" 2>"$T/err"
  ec=$?
  set -e

  [[ "$ec" -eq "$want_ec" ]] || fail "$name: exit $ec, want $want_ec (stderr: $(cat "$T/err"))"
  got_state="$(status_field state)"
  [[ "$got_state" == "$want_state" ]] || fail "$name: status '$got_state', want '$want_state'"
  if [[ -n "$want_desc" ]]; then
    got_desc="$(status_field description)"
    [[ "$got_desc" == "$want_desc" ]] || fail "$name: description '$got_desc', want '$want_desc'"
  fi

  # Allowlist restore must leave the repo writable after every case.
  : > "$REPO/.gate-write-probe" || fail "$name: cannot create file in repo (allowlist not restored)"
  rm -f "$REPO/.gate-write-probe" || fail "$name: cannot remove probe"
  [[ ! -e "$REPO/.factory-cc-fs-state" ]] || fail "$name: allowlist state file left behind"
}

echo "=== PASS verdict ==="
run_gate "pass" 0 success $'GATE: PASS\nok' 0

echo "=== FAIL verdict ==="
run_gate "fail" 1 failure $'GATE: FAIL\nwhy' 0

echo "=== FAIL wins over PASS ==="
run_gate "pass and fail" 1 failure $'GATE: PASS\nsome rationale\nGATE: FAIL' 0

echo "=== PASS must be a whole line ==="
run_gate "inline pass" 75 error 'I think GATE: PASS fits' 0 0 "" "no verdict (step exit=0)"

echo "=== empty output ==="
run_gate "no output" 75 error "" 0 1 "" "no verdict (step exit=1)"

echo "=== step timeout ==="
run_gate "timeout" 124 error $'GATE: PASS\nok' 124 0 "" "step timeout"

echo "=== step failed with a PASS line ==="
run_gate "step exit 1" 75 error $'GATE: PASS\nok' 1 0 "" "no verdict (step exit=1)"

echo "=== stub still writes the configured output ==="
run_gate "stub pass" 0 success "" 0 0 pass
[[ -s "$GATE_OUT" ]] || fail "stub pass: $GATE_OUT was not written"
grep -q 'GATE: PASS' "$GATE_OUT" || fail "stub pass: $GATE_OUT has no PASS"

if [[ "$gate_gone_before" == "__absent__" ]]; then
  [[ ! -e "$GATE_GONE" ]] || fail "$GATE_GONE was created by the test"
else
  gate_gone_after="$(sha256sum "$GATE_GONE" | awk '{print $1}')"
  [[ "$gate_gone_after" == "$gate_gone_before" ]] || fail "$GATE_GONE was modified by the test"
fi

echo "test_gate_claude_verdict: PASS"
