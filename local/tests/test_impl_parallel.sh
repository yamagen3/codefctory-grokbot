#!/usr/bin/env bash
# Prove IMPL parallel resolution (env / spec/IMPL_STRATEGY.md / default 2) fans out
# N workspaces and picks winner by acceptance, without real OpenCode (FACTORY_STEP_BIN mock).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="$ROOT/bin:$PATH"
export FACTORY_ROOT="$ROOT"
T=$(mktemp -d /tmp/impl-parallel-test-XXXXXX)
trap 'rm -rf "$T"; sudo -n rm -rf /var/factory/oc-workspaces/impl-par-test-* /var/factory/oc-homes/impl-par-test-* 2>/dev/null || true' EXIT

# --- mock factory-step: write slot-specific src based on FACTORY_USAGE_STEP ---
MOCK="$T/mock-factory-step"
cat > "$MOCK" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
WS="${FACTORY_OC_WORKSPACE:?}"
HOME_SLOT="${FACTORY_OC_HOME:-}"
STEP="${FACTORY_USAGE_STEP:-}"
# Marker proving this slot ran (keep out of product tree / patch)
if [[ -n "$HOME_SLOT" ]]; then
  echo "ran $STEP ws=$WS home=$HOME_SLOT" > "$HOME_SLOT/ran-marker"
fi
mkdir -p "$WS/src"
# Slot behavior:
#   impl-s1: broken impl (fails acceptance) but nonempty
#   impl-s2: correct impl (passes acceptance)
#   impl-s3: empty (no src change) + exit 0
#   impl-s4: correct but exit 1 (should lose to s2 which also passes + exit 0)
case "$STEP" in
  impl-s1)
    cat > "$WS/src/app.py" <<'PY'
def add(a, b):
    return a - b  # wrong
PY
    echo '{"ok":true,"slot":1}' 
    exit 0
    ;;
  impl-s2)
    cat > "$WS/src/app.py" <<'PY'
def add(a, b):
    return a + b
PY
    echo '{"ok":true,"slot":2}'
    exit 0
    ;;
  impl-s3)
    # leave seed app.py unchanged (empty patch)
    echo '{"ok":true,"slot":3}'
    exit 0
    ;;
  impl-s4)
    cat > "$WS/src/app.py" <<'PY'
def add(a, b):
    return a + b
PY
    echo '{"ok":true,"slot":4}'
    exit 1
    ;;
  *)
    echo "mock-factory-step: unknown step $STEP" >&2
    exit 2
    ;;
esac
MOCK
chmod 755 "$MOCK"

# --- tiny subject repo with failing seed + acceptance ---
REPO="$T/repo"
mkdir -p "$REPO/src" "$REPO/tests/acceptance" "$REPO/spec"
cat > "$REPO/src/app.py" <<'PY'
def add(a, b):
    return 0  # placeholder — fails acceptance
PY
cat > "$REPO/tests/acceptance/test_add.py" <<'PY'
import unittest
from app import add
class T(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(2, 3), 5)
if __name__ == "__main__":
    unittest.main()
PY
echo '# product' > "$REPO/spec/PRODUCT.md"
git init -b main "$REPO" >/dev/null
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -m seed >/dev/null

echo "=== parallel=3 picks s2 (best acceptance + oc exit 0) ==="
export FACTORY_OC_PARALLEL=3
export FACTORY_STEP_BIN="$MOCK"
export FACTORY_USAGE_DISABLE=1
ID=par-test-$$
set +e
factory-impl-step "$REPO" "$ID" "mock prompt" >"$T/out3.txt" 2>&1
EC=$?
set -e
cat "$T/out3.txt"
[[ "$EC" -eq 0 ]] || { echo "expected exit 0"; exit 1; }
grep -q 'winner=s2/3' "$T/out3.txt" || { echo "expected winner s2"; exit 1; }
# workspaces created
ls -d /var/factory/oc-workspaces/impl-${ID}-*-s1 >/dev/null
ls -d /var/factory/oc-workspaces/impl-${ID}-*-s2 >/dev/null
ls -d /var/factory/oc-workspaces/impl-${ID}-*-s3 >/dev/null
# homes created
ls -d /var/factory/oc-homes/impl-${ID}-*-s1 >/dev/null
# result JSON unique per slot
ls "$FACTORY_ROOT/local/logs/impl-${ID}-"*-s1.json >/dev/null
ls "$FACTORY_ROOT/local/logs/impl-${ID}-"*-s2.json >/dev/null
# parallel summary
PJ="$FACTORY_ROOT/local/logs/impl-${ID}-parallel.json"
[[ -f "$PJ" ]]
python3 -c "import json; d=json.load(open('$PJ')); assert d['winner_slot']==2 and d['parallel']==3 and d.get('parallel_source')=='env'"
# repo got correct impl
grep -q 'return a + b' "$REPO/src/app.py"
git -C "$REPO" log -1 --format=%s | grep -q 'slot s2/3'

echo "=== parallel=1 empty → non-zero ==="
# Reset repo to seed-like empty-change scenario: mock only has impl-s1..s4;
# for N=1 usage step is impl-s1 which writes wrong code — still nonempty.
# Build a mock that always leaves tree unchanged for empty test.
MOCK_EMPTY="$T/mock-empty"
cat > "$MOCK_EMPTY" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
WS="${FACTORY_OC_WORKSPACE:?}"
[[ -n "${FACTORY_OC_HOME:-}" ]] && echo ran > "$FACTORY_OC_HOME/ran-marker"
echo '{"ok":true}'
exit 0
MOCK
chmod 755 "$MOCK_EMPTY"
REPO2="$T/repo2"
cp -a "$REPO" "$REPO2"
# reset app to seed
cat > "$REPO2/src/app.py" <<'PY'
def add(a, b):
    return 0
PY
git -C "$REPO2" add -A
git -C "$REPO2" -c user.email=t@t -c user.name=t commit -m reset >/dev/null || true
ID2=par-empty-$$
export FACTORY_OC_PARALLEL=1
export FACTORY_STEP_BIN="$MOCK_EMPTY"
set +e
factory-impl-step "$REPO2" "$ID2" "empty" >"$T/out1.txt" 2>&1
EC=$?
set -e
cat "$T/out1.txt"
[[ "$EC" -ne 0 ]] || { echo "expected non-zero on empty"; exit 1; }
grep -q 'all slots empty/fail' "$T/out1.txt"

echo "=== strategy file parallel=3 (FACTORY_OC_PARALLEL unset) fans out 3 ==="
REPO3="$T/repo3"
cp -a "$REPO" "$REPO3"
# reset product to seed so mock can rewrite
cat > "$REPO3/src/app.py" <<'PY'
def add(a, b):
    return 0
PY
cat > "$REPO3/spec/IMPL_STRATEGY.md" <<'MD'
parallel: 3

Prefer multiple approaches for a non-trivial add fix.
複数アプローチが有効なので N=3。
MD
git -C "$REPO3" add -A
git -C "$REPO3" -c user.email=t@t -c user.name=t commit -m strategy3 >/dev/null
unset FACTORY_OC_PARALLEL || true
export FACTORY_STEP_BIN="$MOCK"
ID3=par-strat-$$
set +e
factory-impl-step "$REPO3" "$ID3" "mock prompt" >"$T/out-strat.txt" 2>&1
EC=$?
set -e
cat "$T/out-strat.txt"
[[ "$EC" -eq 0 ]] || { echo "expected exit 0 from strategy"; exit 1; }
grep -q 'winner=s2/3' "$T/out-strat.txt" || { echo "expected winner s2/3 from strategy"; exit 1; }
grep -q 'parallel=3 source=spec' "$T/out-strat.txt" || { echo "expected source=spec"; exit 1; }
ls -d /var/factory/oc-workspaces/impl-${ID3}-*-s1 >/dev/null
ls -d /var/factory/oc-workspaces/impl-${ID3}-*-s2 >/dev/null
ls -d /var/factory/oc-workspaces/impl-${ID3}-*-s3 >/dev/null
PJ3="$FACTORY_ROOT/local/logs/impl-${ID3}-parallel.json"
python3 -c "import json; d=json.load(open('$PJ3')); assert d['winner_slot']==2 and d['parallel']==3 and d.get('parallel_source')=='spec'"
grep -q 'return a + b' "$REPO3/src/app.py"

echo "=== missing strategy → default parallel=2 ==="
REPO4="$T/repo4"
cp -a "$REPO" "$REPO4"
cat > "$REPO4/src/app.py" <<'PY'
def add(a, b):
    return 0
PY
rm -f "$REPO4/spec/IMPL_STRATEGY.md"
git -C "$REPO4" add -A
git -C "$REPO4" -c user.email=t@t -c user.name=t commit -m nostrategy >/dev/null || true
unset FACTORY_OC_PARALLEL || true
export FACTORY_STEP_BIN="$MOCK"
ID4=par-def-$$
set +e
factory-impl-step "$REPO4" "$ID4" "mock prompt" >"$T/out-def.txt" 2>&1
EC=$?
set -e
cat "$T/out-def.txt"
[[ "$EC" -eq 0 ]] || { echo "expected exit 0 from default"; exit 1; }
grep -q 'winner=s2/2' "$T/out-def.txt" || { echo "expected winner s2/2 from default"; exit 1; }
grep -q 'parallel=2 source=default' "$T/out-def.txt" || { echo "expected source=default"; exit 1; }
grep -qi 'missing spec/IMPL_STRATEGY.md' "$T/out-def.txt" || { echo "expected missing-strategy warning"; exit 1; }
# only 2 slots
ls -d /var/factory/oc-workspaces/impl-${ID4}-*-s1 >/dev/null
ls -d /var/factory/oc-workspaces/impl-${ID4}-*-s2 >/dev/null
if ls -d /var/factory/oc-workspaces/impl-${ID4}-*-s3 >/dev/null 2>&1; then
  echo "did not expect s3 for default=2"; exit 1
fi
PJ4="$FACTORY_ROOT/local/logs/impl-${ID4}-parallel.json"
python3 -c "import json; d=json.load(open('$PJ4')); assert d['winner_slot']==2 and d['parallel']==2 and d.get('parallel_source')=='default'"
grep -q 'return a + b' "$REPO4/src/app.py"

echo "=== launcher rejects workspace outside oc-workspaces ==="
BAD_WS=$(mktemp -d /tmp/bad-ws-XXXXXX)
export FACTORY_OC_WORKSPACE="$BAD_WS"
export FACTORY_OC_API_KEY=dummy-key-for-path-check
set +e
# Run as root path via sudo of launcher (will fail path check early)
sudo -n --preserve-env=FACTORY_OC_API_KEY,FACTORY_OC_WORKSPACE "$ROOT/bin/opencode-acp-isolated" </dev/null >"$T/launch-bad.txt" 2>&1
EC=$?
set -e
cat "$T/launch-bad.txt"
[[ "$EC" -ne 0 ]]
grep -qi 'not under' "$T/launch-bad.txt"
rm -rf "$BAD_WS"
unset FACTORY_OC_WORKSPACE FACTORY_OC_API_KEY

echo "=== launcher rejects FACTORY_OC_HOME outside allowlist ==="
GOOD_WS=$(mktemp -d /var/factory/oc-workspaces/pathcheck-XXXXXX)
BAD_HOME=$(mktemp -d /tmp/bad-home-XXXXXX)
export FACTORY_OC_WORKSPACE="$GOOD_WS"
export FACTORY_OC_HOME="$BAD_HOME"
export FACTORY_OC_API_KEY=dummy-key-for-path-check
set +e
sudo -n --preserve-env=FACTORY_OC_API_KEY,FACTORY_OC_WORKSPACE,FACTORY_OC_HOME \
  "$ROOT/bin/opencode-acp-isolated" </dev/null >"$T/launch-badhome.txt" 2>&1
EC=$?
set -e
cat "$T/launch-badhome.txt"
[[ "$EC" -ne 0 ]]
grep -qi 'FACTORY_OC_HOME' "$T/launch-badhome.txt"
rm -rf "$BAD_HOME"
sudo -n rm -rf "$GOOD_WS" 2>/dev/null || rm -rf "$GOOD_WS"
unset FACTORY_OC_WORKSPACE FACTORY_OC_HOME FACTORY_OC_API_KEY

echo "test_impl_parallel: PASS"
