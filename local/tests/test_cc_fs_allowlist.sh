#!/usr/bin/env bash
# CC FS allowlist (enforcement layer): spec step may write spec/ + tests/acceptance/ only; gate is read-only.
set -euo pipefail
B="$(cd "$(dirname "$0")/../.." && pwd)/bin"
R=$(mktemp -d /tmp/factory-ccfs-XXXXXX); trap 'chmod -R u+w "$R"; rm -rf "$R"' EXIT
cd "$R"; git init -q -b main; mkdir -p spec tests/acceptance src
echo a > spec/PRODUCT.md; echo b > tests/acceptance/t.py; echo c > src/x.py
git -c user.email=t@l -c user.name=t add -A; git -c user.email=t@l -c user.name=t commit -qm s
"$B/factory-cc-fs-allowlist" apply "$R" spec >/dev/null
echo ok >> spec/PRODUCT.md
( echo bad >> src/x.py ) 2>/dev/null && { echo "FAIL src writable in spec"; exit 1; }
"$B/factory-cc-fs-allowlist" restore "$R" >/dev/null
"$B/factory-cc-fs-allowlist" verify "$R" spec >/dev/null || { echo "FAIL verify spec (allowed change)"; exit 1; }
echo tamper >> src/x.py
"$B/factory-cc-fs-allowlist" verify "$R" spec >/dev/null 2>&1 && { echo "FAIL verify accepted src change"; exit 1; }
git checkout -q -- src
"$B/factory-cc-fs-allowlist" apply "$R" gate >/dev/null
( echo bad >> spec/PRODUCT.md ) 2>/dev/null && { echo "FAIL spec writable in gate"; exit 1; }
"$B/factory-cc-fs-allowlist" restore "$R" >/dev/null
echo "test_cc_fs_allowlist: PASS"
