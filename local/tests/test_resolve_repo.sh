#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/../../bin" && pwd)/factory-common.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Relative path from factory root. The bare origin is a fixture this test creates.
# local/origin/*.git is gitignored and existed only on the original host.
cd "$ROOT"
WORK_REL="local/work/_resolve-repo-smoke"
FIX="$(mktemp -d /tmp/factory-resolve-origin-XXXXXX)"
cleanup() { rm -rf "$FIX" "$ROOT/$WORK_REL"; }
trap cleanup EXIT
git init --bare -b main "$FIX/origin.git" >/dev/null
SEED="$(mktemp -d)"
echo fixture > "$SEED/README.md"
git -C "$SEED" init -b main >/dev/null
git -C "$SEED" -c user.email=factory@localhost -c user.name=factory add README.md
git -C "$SEED" -c user.email=factory@localhost -c user.name=factory commit -m seed >/dev/null
git -C "$SEED" remote add origin "$FIX/origin.git"
git -C "$SEED" push -u origin main >/dev/null
rm -rf "$SEED"
rm -rf "$WORK_REL"
git clone "$FIX/origin.git" "$WORK_REL" >/dev/null 2>&1
ABS=$(resolve_repo "$WORK_REL")
[[ "$ABS" == /* ]] || { echo "FAIL not absolute: $ABS"; exit 1; }
[[ -d "$ABS/.git" ]] || { echo "FAIL no .git"; exit 1; }
# Relative from a different cwd
cd /tmp
ABS2=$(resolve_repo "$ROOT/$WORK_REL")
[[ "$ABS" == "$ABS2" ]] || { echo "FAIL mismatch $ABS vs $ABS2"; exit 1; }
# factory-merge should at least resolve + checkout branch without path error
# (will fail required-ok — that's fine; we only assert it gets past checkout)
cd "$ROOT"
set +e
OUT=$(factory-merge "$WORK_REL" "no-such-id-for-path-test" 2>&1)
EC=$?
set -e
# Should NOT be "fatal: not a git repository" / exit 128 from bad relative path before checkout
if echo "$OUT" | grep -qi 'not a git repository'; then
  echo "FAIL relative path still broken: $OUT"; exit 1
fi
# Expected: branch missing or required-ok — either means resolve+cd worked
echo "OK resolve_repo smoke (merge reached git ops; ec=$EC)"
echo "$OUT" | head -5
