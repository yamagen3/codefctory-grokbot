#!/usr/bin/env bash
# Offline tests for the model profile and bin/factory-profile.
# A fake factory root is built by copying the real checked files; no model,
# network, or provider call is made.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d /tmp/factory-profile-XXXXXX)"
trap 'rm -rf "$T"' EXIT
fail() { echo "test_factory_profile: FAIL $*" >&2; exit 1; }

unset FACTORY_MODEL_PROFILE || true
BASE="$T/root"
FILES=(
  config/factory.patch.yml
  bin/factory-common.sh
  bin/factory-run-local
  bin/factory-stall-retry
  bin/factory-impl-step
  bin/factory-spec-step
  bin/factory-gate-claude
  bin/factory-profile
  lib/factory_usage.py
)

make_root() {
  local dest="$1" relative
  rm -rf "$dest"
  mkdir -p "$dest/config" "$dest/bin" "$dest/profiles"
  for relative in "${FILES[@]}"; do
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

echo "=== (a) default profile: check ok, id, and get ==="
make_root "$BASE"
out=$(run_profile "$BASE" check) || fail "(a) check exited non-zero: $out"
[[ "$out" == "ok" ]] || fail "(a) check printed: $out"
[[ "$(run_profile "$BASE" id)" == "default" ]] || fail "(a) id is not default"
[[ "$(run_profile "$BASE" get brain.model)" == "claude-opus-5-5" ]] \
  || fail "(a) get brain.model is not claude-opus-5-5"

set +e
run_profile "$BASE" get no.such.key >/dev/null 2>&1
GET_RC=$?
set -e
[[ "$GET_RC" -eq 1 ]] || fail "(a) get on a missing key exited $GET_RC, want 1"

echo "=== (b) brain effort drift is named ==="
make_root "$BASE"
python3 - "$BASE/config/factory.patch.yml" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
want = "CLAUDE_CODE_EFFORT_LEVEL: 'xhigh'"
assert want in text, text
path.write_text(text.replace(want, "CLAUDE_CODE_EFFORT_LEVEL: 'high'"))
PY
set +e
out=$(run_profile "$BASE" check 2>&1)
CHECK_RC=$?
set -e
[[ "$CHECK_RC" -eq 1 ]] || fail "(b) check exited $CHECK_RC, want 1: $out"
grep -q 'brain\.effort' <<<"$out" || fail "(b) mismatch did not name brain.effort: $out"

echo "=== (c) max-rounds drift is named ==="
make_root "$BASE"
python3 - "$BASE/bin/factory-run-local" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
want = "FACTORY_MAX_ROUNDS:-3}"
assert want in text, text
path.write_text(text.replace(want, "FACTORY_MAX_ROUNDS:-5}"))
PY
set +e
out=$(run_profile "$BASE" check 2>&1)
CHECK_RC=$?
set -e
[[ "$CHECK_RC" -eq 1 ]] || fail "(c) check exited $CHECK_RC, want 1: $out"
grep -q 'loop\.max_rounds' <<<"$out" \
  || fail "(c) mismatch did not name loop.max_rounds: $out"

echo "=== (d) credential-looking profile key is rejected ==="
make_root "$BASE"
python3 - "$BASE/profiles/default.json" "$BASE/profiles/bad.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    doc = json.load(fh)
doc["api_key"] = "redacted"
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
    fh.write("\n")
PY
set +e
out=$(FACTORY_ROOT="$BASE" FACTORY_MODEL_PROFILE=bad "$BASE/bin/factory-profile" check 2>&1)
CHECK_RC=$?
set -e
[[ "$CHECK_RC" -ne 0 ]] || fail "(d) profile with api_key was accepted"
grep -qi 'api_key' <<<"$out" || fail "(d) rejection did not name api_key: $out"

echo "=== (e) path-like selection is rejected ==="
set +e
out=$(FACTORY_ROOT="$BASE" FACTORY_MODEL_PROFILE=../x "$BASE/bin/factory-profile" id 2>&1)
CHECK_RC=$?
set -e
[[ "$CHECK_RC" -ne 0 ]] || fail "(e) ../x was accepted"
grep -q 'FACTORY_MODEL_PROFILE' <<<"$out" \
  || fail "(e) rejection did not name FACTORY_MODEL_PROFILE: $out"

echo "=== (f) missing profile exits non-zero with a clear message ==="
set +e
out=$(FACTORY_ROOT="$BASE" FACTORY_MODEL_PROFILE=missing "$BASE/bin/factory-profile" check 2>&1)
CHECK_RC=$?
set -e
[[ "$CHECK_RC" -ne 0 ]] || fail "(f) missing profile was accepted"
grep -qi 'missing' <<<"$out" || fail "(f) message does not name the profile: $out"
grep -qi 'not found\|cannot read' <<<"$out" \
  || fail "(f) message does not say the profile is missing: $out"

echo "=== (h) model drift is named ==="
make_root "$BASE"
python3 - "$BASE/config/factory.patch.yml" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
want = "model: claude-opus-5-5"
assert want in text, text
path.write_text(text.replace(want, "model: claude-opus-5-5-x", 1))
PY
set +e
out=$(run_profile "$BASE" check 2>&1)
CHECK_RC=$?
set -e
[[ "$CHECK_RC" -eq 1 ]] || fail "(h) check exited $CHECK_RC, want 1: $out"
grep -q 'brain\.model' <<<"$out" || fail "(h) mismatch did not name brain.model: $out"

echo "=== (i) parallel default drift is named ==="
make_root "$BASE"
python3 - "$BASE/bin/factory-impl-step" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
want = "PARALLEL=2"
assert text.count(want) >= 1, text
path.write_text(text.replace(want, "PARALLEL=3", 1))
PY
set +e
out=$(run_profile "$BASE" check 2>&1)
CHECK_RC=$?
set -e
[[ "$CHECK_RC" -eq 1 ]] || fail "(i) check exited $CHECK_RC, want 1: $out"
grep -q 'maker\.parallel_default' <<<"$out" \
  || fail "(i) mismatch did not name maker.parallel_default: $out"

echo "=== (j) the real checkout matches its profile ==="
out=$(FACTORY_ROOT="$ROOT" "$ROOT/bin/factory-profile" check) \
  || fail "(j) real checkout check failed: $out"
[[ "$out" == "ok" ]] || fail "(j) real checkout check printed: $out"

echo "test_factory_profile: PASS"
