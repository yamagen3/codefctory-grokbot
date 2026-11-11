#!/usr/bin/env bash
# factory-update: classification, lock, apply success, and simulated failed update -> automatic rollback.
# Uses a fake npm package in a throwaway prefix + mocked verify/doctor. Never touches the real install.
set -euo pipefail
FU="$(cd "$(dirname "$0")/../.." && pwd)/bin/factory-update"
T=$(mktemp -d /tmp/factory-update-test-XXXXXX); trap 'rm -rf "$T"' EXIT
export FACTORY_UPDATE_DIR="$T/updates" FACTORY_UPDATE_NPM_PREFIX="$T/prefix" FACTORY_UPDATE_SKIP_POST=1 FACTORY_UPDATE_DOCTOR_CMD=true
mk() { mkdir -p "$T/src/$1/bin"; cat > "$T/src/$1/package.json" <<J
{"name":"factory-fake-pkg","version":"$1","bin":{"factory-fake":"bin/f.js"}}
J
  printf '#!/usr/bin/env node\nconsole.log("%s")\n' "$1" > "$T/src/$1/bin/f.js"; (cd "$T/src/$1" && npm pack --silent --pack-destination "$T" >/dev/null); }
mk 1.0.0; mk 1.0.1
npm install -g --prefix "$T/prefix" --no-audit --no-fund "$T/factory-fake-pkg-1.0.0.tgz" >/dev/null
plan() { cat > "$T/plan.json" <<J
{"actions":[{"id":"npm:factory-fake-pkg@1.0.1","kind":"npm","name":"factory-fake-pkg","from":"1.0.0","to":"1.0.1","spec":"$T/factory-fake-pkg-1.0.1.tgz","class":"auto","reason":"patch"},
 {"id":"x","kind":"info","name":"@deepseek-ai/dsh","from":"0.2.1-rc.5","to":"0.2.2-rc.1","class":"needs-approval","reason":"rc"}],"errors":[],"warnings":[]}
J
}
ver() { "$T/prefix/bin/factory-fake"; }
fail=0; t() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

# 1) classification rules
t "classify" "python3 - <<'PY'
import importlib.machinery,importlib.util
l=importlib.machinery.SourceFileLoader('fu','$FU'); s=importlib.util.spec_from_loader('fu',l); m=importlib.util.module_from_spec(s); l.exec_module(m)
c=m.classify
assert c('1.7.0','1.7.1')[0]=='auto' and c('2.2.5','2.3.0')[0]=='auto'
assert c('2.2.5','3.0.0')[0]=='needs-approval' and c('0.3.263','0.4.0')[0]=='needs-approval'
assert c('0.2.1-rc.5','0.2.1',rule='dsh')[0]=='needs-approval' and c('0.2.1-rc.5','0.2.2-rc.1',rule='dsh')[0]=='needs-approval'
assert c('1.0.0','1.0.0')[0]=='none'
assert m.fixed_for({'version':'8.11.2','fixed':['6.29.1','7.30.1','8.12.0']})=='8.12.0'
PY"

# 2) simulated failed update -> rollback
plan; set +e; FACTORY_UPDATE_VERIFY_CMD='echo simulated verify failure; exit 7' "$FU" apply --check-json "$T/plan.json" >/dev/null 2>&1; rc=$?; set -e
t "rollback exit 30" "[ $rc -eq 30 ]"
t "rollback restored 1.0.0" "[ \"\$(ver)\" = 1.0.0 ]"
t "summary rolled-back w/ reason" "grep -q 'status: \*\*rolled-back' $T/updates/latest-summary.md && grep -q 'verify step verify-override failed rc=7' $T/updates/latest-summary.md"
t "log entry" "grep -q rolled-back $T/updates/UPDATES-LOG.md"

# 3) failure during install itself (bad tarball) -> rollback, version untouched
sed -i "s#factory-fake-pkg-1.0.1.tgz#missing.tgz#" "$T/plan.json"; set +e; FACTORY_UPDATE_VERIFY_CMD=true "$FU" apply --check-json "$T/plan.json" >/dev/null 2>&1; rc=$?; set -e
t "install failure -> 30 and 1.0.0" "[ $rc -eq 30 ] && [ \"\$(ver)\" = 1.0.0 ]"

# 4) success -> applied, pending approval reported
plan; set +e; FACTORY_UPDATE_VERIFY_CMD=true "$FU" apply --check-json "$T/plan.json" >/dev/null 2>&1; rc=$?; set -e
t "success applied 1.0.1 (exit 20: applied + needs-approval)" "[ $rc -eq 20 ] && [ \"\$(ver)\" = 1.0.1 ]"
t "summary lists needs-approval" "grep -q '0.2.2-rc.1' $T/updates/latest-summary.md && grep -q 'applied: npm:factory-fake-pkg@1.0.1' $T/updates/latest-summary.md"

# 5) nothing-to-do
echo '{"actions":[],"errors":[],"warnings":[]}' > "$T/empty.json"
set +e; "$FU" apply --check-json "$T/empty.json" >/dev/null 2>&1; rc=$?; set -e
t "nothing-to-do exit 0" "[ $rc -eq 0 ] && grep -q nothing-to-do $T/updates/latest-summary.md"

# 6) --approve: needs-approval item stays put by default, applies only when explicitly approved
mk 1.0.2 >/dev/null
cat > "$T/appr.json" <<J
{"actions":[{"id":"npm:factory-fake-pkg@1.0.2","kind":"npm","name":"factory-fake-pkg","from":"1.0.1","to":"1.0.2","spec":"$T/factory-fake-pkg-1.0.2.tgz","class":"needs-approval","reason":"rc"}],"errors":[],"warnings":[]}
J
set +e; FACTORY_UPDATE_VERIFY_CMD=true "$FU" apply --check-json "$T/appr.json" >/dev/null 2>&1; rc=$?; set -e
t "unapproved stays (exit 20, 1.0.1)" "[ $rc -eq 20 ] && [ \"\$(ver)\" = 1.0.1 ]"
set +e; FACTORY_UPDATE_VERIFY_CMD=true "$FU" apply --check-json "$T/appr.json" --approve factory-fake-pkg@1.0.2 >/dev/null 2>&1; rc=$?; set -e
t "approved applies (exit 10, 1.0.2)" "[ $rc -eq 10 ] && [ \"\$(ver)\" = 1.0.2 ]"
set +e; "$FU" apply --check-json "$T/appr.json" --approve nope >/dev/null 2>&1; rc=$?; set -e
t "unknown approval -> error 1" "[ $rc -eq 1 ]"

# 7) lock: second run while the lock is held
mkdir -p "$T/updates"; set +e
flock "$T/updates/.lock" -c "\"$FU\" apply --check-json \"$T/empty.json\" >/dev/null 2>&1; echo \$? > $T/lockrc"; set -e
t "lock held -> 75" "[ \$(cat $T/lockrc) -eq 75 ]"

[ $fail -eq 0 ] && echo "test_factory_update: PASS" || { echo "test_factory_update: FAIL"; exit 1; }
