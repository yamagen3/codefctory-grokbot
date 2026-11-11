#!/usr/bin/env bash
set -euo pipefail
export PATH="$(cd "$(dirname "$0")/../.." && pwd)/bin:$PATH"
T=$(mktemp -d /tmp/patch-test-XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/clean/src" "$T/oc/src" "$T/clean/spec" "$T/oc/spec"
echo 'old' > "$T/clean/src/a.py"
echo 'new' > "$T/oc/src/a.py"
echo 'spec' > "$T/clean/spec/PRODUCT.md"
echo 'HACKED' > "$T/oc/spec/PRODUCT.md"

echo "=== make strips protected + allows src ==="
factory-patch-extract make "$T/oc" "$T/clean" "$T/ok.patch"
grep -q 'src/a.py' "$T/ok.patch"
! grep -q 'spec/PRODUCT' "$T/ok.patch"
factory-patch-extract check "$T/ok.patch"

echo "=== check refuses protected path in handcrafted patch ==="
cat > "$T/bad-prot.patch" <<'P'
diff -ruN a/spec/PRODUCT.md b/spec/PRODUCT.md
--- a/spec/PRODUCT.md
+++ b/spec/PRODUCT.md
@@ -1 +1 @@
-spec
+HACKED
P
set +e
factory-patch-extract check "$T/bad-prot.patch"
EC=$?
set -e
[[ "$EC" -ne 0 ]] || { echo "expected fail"; exit 1; }

echo "=== check refuses binary marker ==="
cat > "$T/bad-bin.patch" <<'P'
Binary files a/src/x.bin and b/src/x.bin differ
P
set +e
factory-patch-extract check "$T/bad-bin.patch"; EC=$?; set -e
[[ "$EC" -ne 0 ]]

echo "=== check refuses symlink mode ==="
cat > "$T/bad-link.patch" <<'P'
diff --git a/src/l b/src/l
new file mode 120000
--- /dev/null
+++ b/src/l
@@ -0,0 +1 @@
+target
P
set +e
factory-patch-extract check "$T/bad-link.patch"; EC=$?; set -e
[[ "$EC" -ne 0 ]]

echo "=== make refuses symlink in OC tree ==="
ln -s /etc/passwd "$T/oc/src/evil.link"
set +e
factory-patch-extract make "$T/oc" "$T/clean" "$T/sym.patch"; EC=$?; set -e
[[ "$EC" -ne 0 ]]
rm -f "$T/oc/src/evil.link"

echo "=== apply ok patch to repo ==="
REPO="$T/repo"
mkdir -p "$REPO"
git init -b main "$REPO" >/dev/null
cp -a "$T/clean"/. "$REPO"/
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -m c >/dev/null
factory-patch-extract apply "$REPO" "$T/ok.patch"
grep -q new "$REPO/src/a.py"
grep -q spec "$REPO/spec/PRODUCT.md"  # unchanged

echo "test_patch_extract: PASS"
