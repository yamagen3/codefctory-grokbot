#!/usr/bin/env bash
# factory-update: a provider outage is deferred (exit 40), not reported as rolled-back (exit 30).
# Uses a fake npm package in a throwaway prefix + mocked provider/verify/doctor. Never touches the real install.
set -euo pipefail
FU="$(cd "$(dirname "$0")/../.." && pwd)/bin/factory-update"
T=$(mktemp -d /tmp/factory-update-provider-test-XXXXXX); trap 'rm -rf "$T"' EXIT
export FACTORY_UPDATE_DIR="$T/updates" FACTORY_UPDATE_NPM_PREFIX="$T/prefix" FACTORY_UPDATE_SKIP_POST=1 FACTORY_UPDATE_DOCTOR_CMD=true FACTORY_NOTIFY_DIR="$T/notify"
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

# (a) pre-flight says CC is limited -> nothing applied, no snapshot, notify written
plan; set +e
FACTORY_UPDATE_PROVIDER_CHECK_CMD='echo limited 1999999999 x; exit 75' "$FU" apply --check-json "$T/plan.json" >/dev/null 2>&1; rc=$?
set -e
applydir=$(find "$T/updates" -type d -name 'apply-*' | sort | tail -1)
t "pre-flight limited -> exit 40" "[ $rc -eq 40 ]"
t "pre-flight applied nothing (1.0.0)" "[ \"\$(ver)\" = 1.0.0 ]"
t "pre-flight summary deferred-provider w/ reason" "grep -q 'status: \*\*deferred-provider' $T/updates/latest-summary.md && grep -q 'claude-code limited: limited 1999999999 x' $T/updates/latest-summary.md"
t "pre-flight no snapshot" "[ -n \"$applydir\" ] && [ ! -d \"$applydir/snapshot\" ]"
t "pre-flight notify file" "ls $T/notify/*-update-deferred.txt >/dev/null 2>&1"

# (b) CC rate limit during verify -> rollback to verified state but deferred-provider, not rolled-back
plan; set +e
FACTORY_UPDATE_PROVIDER_CHECK_CMD=true \
FACTORY_UPDATE_VERIFY_CMD="echo \"You've hit your 5-hour limit · resets 6am (Asia/Tokyo)\"; exit 1" \
"$FU" apply --check-json "$T/plan.json" >/dev/null 2>&1; rc=$?
set -e
t "verify rate-limit -> exit 40" "[ $rc -eq 40 ]"
t "verify rate-limit restored 1.0.0" "[ \"\$(ver)\" = 1.0.0 ]"
t "verify rate-limit summary deferred-provider + not regression" "grep -q 'status: \*\*deferred-provider' $T/updates/latest-summary.md && grep -q 'not a regression' $T/updates/latest-summary.md"

# (c) ordinary verify failure still rolls back (exit 30)
plan; set +e
FACTORY_UPDATE_PROVIDER_CHECK_CMD=true FACTORY_UPDATE_VERIFY_CMD='echo simulated verify failure; exit 7' "$FU" apply --check-json "$T/plan.json" >/dev/null 2>&1; rc=$?
set -e
t "ordinary verify failure -> exit 30 rolled-back" "[ $rc -eq 30 ] && [ \"\$(ver)\" = 1.0.0 ] && grep -q 'status: \*\*rolled-back' $T/updates/latest-summary.md"

# (d) verify step rc 75 -> provider outage
plan; set +e
FACTORY_UPDATE_PROVIDER_CHECK_CMD=true FACTORY_UPDATE_VERIFY_CMD='exit 75' "$FU" apply --check-json "$T/plan.json" >/dev/null 2>&1; rc=$?
set -e
t "verify rc 75 -> exit 40" "[ $rc -eq 40 ] && [ \"\$(ver)\" = 1.0.0 ] && grep -q 'status: \*\*deferred-provider' $T/updates/latest-summary.md"
t "log shows deferred-provider" "grep -q deferred-provider $T/updates/UPDATES-LOG.md"

[ $fail -eq 0 ] && echo "test_factory_update_provider: PASS" || { echo "test_factory_update_provider: FAIL"; exit 1; }
