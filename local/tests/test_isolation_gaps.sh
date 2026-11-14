#!/usr/bin/env bash
# Isolation gaps: patch extractor refuses symlinked directories; unknown CC step is denied.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d /tmp/isolation-gaps-XXXXXX)
trap 'rm -rf "$T"' EXIT

NODE="$(command -v node || true)"
if [[ -z "$NODE" ]]; then
  for cand in /usr/local/bin/node /usr/bin/node /opt/homebrew/bin/node; do
    if [[ -x "$cand" ]]; then NODE="$cand"; break; fi
  done
fi
[[ -n "$NODE" ]] || { echo "FAIL: node not found"; exit 1; }

mkdir -p "$T/clean" "$T/oc" "$T/target"
echo 'same' > "$T/clean/a.txt"
echo 'same' > "$T/oc/a.txt"
echo 'inside target' > "$T/target/file.txt"
ln -s "$T/target" "$T/oc/x"

echo "=== make refuses symlinked directory ==="
set +e
OUT=$("$ROOT/bin/factory-patch-extract" make "$T/oc" "$T/clean" "$T/symlink.patch" 2>&1)
EC=$?
set -e
[[ "$EC" -ne 0 ]] || { echo "FAIL: symlinked directory was accepted"; exit 1; }
grep -q 'symlink: x' <<<"$OUT" || { echo "FAIL: missing 'symlink: x'"; echo "$OUT"; exit 1; }

echo "=== make still produces a patch without symlinks ==="
rm "$T/oc/x"
echo 'changed' > "$T/oc/a.txt"
"$ROOT/bin/factory-patch-extract" make "$T/oc" "$T/clean" "$T/clean.patch" >/dev/null
grep -q 'a.txt' "$T/clean.patch" || { echo "FAIL: patch missing a.txt"; exit 1; }
"$ROOT/bin/factory-patch-extract" check "$T/clean.patch" >/dev/null

echo "=== allowlist denies unknown step ==="
ALLOWLIST="$ROOT/lib/cc/allowlist.js" "$NODE" --input-type=module <<'JS'
import assert from 'node:assert/strict'
import { pathToFileURL } from 'node:url'

const { isWriteAllowed, makeCanUseTool } = await import(pathToFileURL(process.env.ALLOWLIST).href)
const cwd = '/tmp/factory-prod'

assert.equal(isWriteAllowed('unknown-step', cwd, 'spec/PRODUCT.md'), false)
const canUnknown = makeCanUseTool('unknown-step', cwd)
const result = await canUnknown('Read', { file_path: `${cwd}/spec/PRODUCT.md` })
assert.equal(result.behavior, 'deny')
assert.match(result.message, /unknown step/i)
JS

echo "test_isolation_gaps: PASS"
