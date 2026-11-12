#!/usr/bin/env bash
# R2-T5: patch-extract cache excludes, LocalBackend sha validation, docs threshold.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "test_r2_small_fixes: FAIL $*" >&2; exit 1; }
# Some images install node in /usr/local/bin without putting it on PATH.
if ! command -v node >/dev/null 2>&1 && [[ -x /usr/local/bin/node ]]; then
  PATH="/usr/local/bin:$PATH"
  export PATH
fi
T="$(mktemp -d /tmp/r2-small-fixes-XXXXXX)"
trap 'rm -rf "$T"' EXIT

# (a) make skips cache/venv dirs in both tars, so they never reach the diff.
mkdir -p "$T/clean" "$T/oc"
echo old > "$T/clean/a.txt"
echo new > "$T/oc/a.txt"
for d in .venv/lib .pytest_cache .mypy_cache .ruff_cache venv/lib; do
  mkdir -p "$T/clean/$d" "$T/oc/$d"
  echo "clean $d" > "$T/clean/$d/x.py"
  echo "oc $d" > "$T/oc/$d/x.py"
done
"$ROOT/bin/factory-patch-extract" make "$T/oc" "$T/clean" "$T/out.patch"
grep -q 'a\.txt' "$T/out.patch" || fail "patch missing changed a.txt"
if grep -Eq '\.venv|\.pytest_cache|\.mypy_cache|\.ruff_cache|(^|/)venv/' "$T/out.patch"; then
  fail "patch contains an ignored cache/venv tree"
fi

# (b) every LocalBackend path built from sha rejects traversal.
mkdir -p "$T/state/status" "$T/state/labels" "$T/state/prs" "$T/state/root"
env FACTORY_STATUS_DIR="$T/state/status" \
  FACTORY_LABELS_DIR="$T/state/labels" \
  FACTORY_PR_DIR="$T/state/prs" \
  FACTORY_ROOT="$T/state/root" \
  PYTHONPATH="$ROOT/lib" \
  python3 - "$T/repo" <<'PY'
import sys
from factory_github.client import LocalBackend

repo = sys.argv[1]
backend = LocalBackend()
for name, call in (
    ("status_get", lambda: backend.status_get(repo, "../x")),
    ("status_required_ok", lambda: backend.status_required_ok(repo, "../x")),
):
    try:
        call()
    except ValueError:
        continue
    raise SystemExit(f"{name} accepted invalid sha")
print("OK invalid sha rejected")
PY

# (c) fresh-path regression test.
echo "=== test_fresh_paths ==="
bash "$ROOT/local/tests/test_fresh_paths.sh" || fail "test_fresh_paths failed"

# (d) docs state the real default and its override, not the old 18 floor.
if grep -q 'acceptance ≥ 18' "$ROOT/docs/layout.md"; then
  fail "docs/layout.md still claims acceptance >= 18"
fi
grep -q 'acceptance ≥ 10' "$ROOT/docs/layout.md" || fail "docs/layout.md does not state acceptance >= 10"
grep -q 'FACTORY_UPDATE_MIN_ACCEPTANCE' "$ROOT/docs/layout.md" || fail "docs/layout.md does not name the override variable"

echo "test_r2_small_fixes: PASS"
