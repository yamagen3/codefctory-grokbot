#!/usr/bin/env bash
# gate/grok full-diff bundle. The original host cloned local/origin/factory-timeline.git,
# which is gitignored and not in a fresh checkout. This test builds the same shape:
# a bare origin with main, a factory branch, and a spec tag at the parent commit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="$ROOT/bin:$PATH"
export FACTORY_ROOT="$ROOT"
FIX="$(mktemp -d /tmp/factory-full-diff-XXXX)"
trap 'rm -rf "$FIX"' EXIT
git init --bare -b main "$FIX/origin.git" >/dev/null
SEED="$(mktemp -d)"
mkdir -p "$SEED"
echo base > "$SEED/README.md"
git -C "$SEED" init -b main >/dev/null
git -C "$SEED" -c user.email=factory@localhost -c user.name=factory add README.md
git -C "$SEED" -c user.email=factory@localhost -c user.name=factory commit -m base >/dev/null
git -C "$SEED" remote add origin "$FIX/origin.git"
git -C "$SEED" push -u origin main >/dev/null
rm -rf "$SEED"
WORK="$FIX/work"
git clone "$FIX/origin.git" "$WORK" >/dev/null
cd "$WORK"
ID=full-diff-smoke
git checkout -B "factory/${ID}"
echo "smoke $(date -Iseconds)" >> README.md
git -c user.email=factory@localhost -c user.name=factory add README.md
git -c user.email=factory@localhost -c user.name=factory commit -m "smoke: full diff" >/dev/null
git tag -f "spec/${ID}" HEAD^
SHA=$(git rev-parse HEAD)
export FACTORY_GROK_HOOK_DIR="$FIX/hooks"
mkdir -p "$FACTORY_GROK_HOOK_DIR"
factory-gate-grok bundle "$WORK" "$ID" "$SHA" >/tmp/bundle-out.txt
BUNDLE=$(tail -1 /tmp/bundle-out.txt)
echo "BUNDLE=$BUNDLE"
test -f "$BUNDLE/diff.patch"
test -f "$BUNDLE/diff.stat.txt"
test -f "$BUNDLE/diff.full.patch"
test -f "$BUNDLE/diff.full.stat.txt"
test -f "$BUNDLE/diff.full.meta.txt"
grep -q 'merge_base=' "$BUNDLE/diff.full.meta.txt"
grep -q 'diff.full.patch' "$BUNDLE/README.md"
grep -q 'README.md' "$BUNDLE/diff.full.stat.txt"
echo "OK gate-grok full diff smoke"
