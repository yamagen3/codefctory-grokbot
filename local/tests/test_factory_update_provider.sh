#!/usr/bin/env bash
# factory-update: provider outage evidence, bounded pre-flight wait, and deferral streak.
# Uses a fake npm package in a throwaway prefix + mocked provider/wait/verify/doctor. Never touches the real install.
set -euo pipefail
FU="$(cd "$(dirname "$0")/../.." && pwd)/bin/factory-update"
T=$(mktemp -d /tmp/factory-update-provider-test-XXXXXX); trap 'rm -rf "$T"' EXIT
export FACTORY_UPDATE_DIR="$T/updates" FACTORY_UPDATE_NPM_PREFIX="$T/prefix" FACTORY_UPDATE_SKIP_POST=1 FACTORY_UPDATE_DOCTOR_CMD=true FACTORY_NOTIFY_DIR="$T/notify"
mk() { mkdir -p "$T/src/$1/bin"; cat > "$T/src/$1/package.json" <<J
{"name":"factory-fake-pkg","version":"$1","bin":{"factory-fake":"bin/f.js"}}
J
  printf '#!/usr/bin/env node\nconsole.log("%s")\n' "$1" > "$T/src/$1/bin/f.js"; (cd "$T/src/$1" && npm pack --silent --pack-destination "$T" >/dev/null); }
mk 1.0.0; mk 1.0.1
install100() { npm install -g --prefix "$T/prefix" --no-audit --no-fund "$T/factory-fake-pkg-1.0.0.tgz" >/dev/null; }
install100
plan() { cat > "$T/plan.json" <<J
{"actions":[{"id":"npm:factory-fake-pkg@1.0.1","kind":"npm","name":"factory-fake-pkg","from":"1.0.0","to":"1.0.1","spec":"$T/factory-fake-pkg-1.0.1.tgz","class":"auto","reason":"patch"},
 {"id":"x","kind":"info","name":"@deepseek-ai/dsh","from":"0.2.1-rc.5","to":"0.2.2-rc.1","class":"needs-approval","reason":"rc"}],"errors":[],"warnings":[]}
J
}
ver() { "$T/prefix/bin/factory-fake"; }
fail=0; t() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

cat > "$T/check-75.sh" <<'S'
#!/usr/bin/env bash
echo "limited 1999999999 x"
exit 75
S
cat > "$T/check-once-limited.sh" <<'S'
#!/usr/bin/env bash
n=0
[ -f "$COUNT_FILE" ] && n=$(cat "$COUNT_FILE")
n=$((n + 1)); echo "$n" > "$COUNT_FILE"
if [ "$n" -eq 1 ]; then
  echo "limited 1999999999 x"
  exit 75
fi
exit 0
S
cat > "$T/check-first-ok.sh" <<'S'
#!/usr/bin/env bash
n=0
[ -f "$COUNT_FILE" ] && n=$(cat "$COUNT_FILE")
n=$((n + 1)); echo "$n" > "$COUNT_FILE"
if [ "$n" -eq 1 ]; then
  exit 0
fi
echo "limited 1999999999 x"
exit 75
S
cat > "$T/wait-75.sh" <<'S'
#!/usr/bin/env bash
[ -n "${WAIT_LOG:-}" ] && echo ran >> "$WAIT_LOG"
exit 75
S
cat > "$T/wait-ok.sh" <<'S'
#!/usr/bin/env bash
[ -n "${WAIT_LOG:-}" ] && echo ran >> "$WAIT_LOG"
exit 0
S
chmod +x "$T"/*.sh

# (a) pre-flight limited and the wait cannot clear it -> nothing applied, no snapshot, notify written
plan; install100; set +e
FACTORY_UPDATE_PROVIDER_CHECK_CMD="$T/check-75.sh" \
FACTORY_UPDATE_PROVIDER_WAIT_CMD="$T/wait-75.sh" \
WAIT_LOG="$T/wait-a.log" \
"$FU" apply --check-json "$T/plan.json" >/dev/null 2>&1; rc=$?
set -e
applydir=$(find "$T/updates" -type d -name 'apply-*' | sort | tail -1)
t "pre-flight limited -> exit 40" "[ $rc -eq 40 ]"
t "pre-flight applied nothing (1.0.0)" "[ \"\$(ver)\" = 1.0.0 ]"
t "pre-flight wait ran" "grep -q ran $T/wait-a.log"
t "pre-flight summary deferred-provider w/ reason" "grep -q 'status: \*\*deferred-provider' $T/updates/latest-summary.md && grep -q 'claude-code limited: limited 1999999999 x' $T/updates/latest-summary.md"
t "pre-flight no snapshot" "[ -n \"$applydir\" ] && [ ! -d \"$applydir/snapshot\" ]"
t "pre-flight notify file" "ls $T/notify/*-update-deferred.txt >/dev/null 2>&1"

# (b) check limited once, wait clears it, second check ok -> the apply proceeds
plan; install100; rm -f "$T/check-b.count"; set +e
COUNT_FILE="$T/check-b.count" WAIT_LOG="$T/wait-b.log" \
FACTORY_UPDATE_PROVIDER_CHECK_CMD="$T/check-once-limited.sh" \
FACTORY_UPDATE_PROVIDER_WAIT_CMD="$T/wait-ok.sh" \
FACTORY_UPDATE_VERIFY_CMD=true \
"$FU" apply --check-json "$T/plan.json" >/dev/null 2>&1; rc=$?
set -e
t "wait cleared -> applied 1.0.1 (exit 20)" "[ $rc -eq 20 ] && [ \"\$(ver)\" = 1.0.1 ]"
t "wait ran before retry" "grep -q ran $T/wait-b.log"
t "wait cleared -> streak removed" "[ ! -e $T/updates/deferred-streak.json ]"

# (c) generic marker during verify + provider check ok -> ordinary rollback, not deferred
plan; install100; set +e
FACTORY_UPDATE_PROVIDER_CHECK_CMD=true \
FACTORY_UPDATE_VERIFY_CMD='echo rate_limit_error; exit 1' \
"$FU" apply --check-json "$T/plan.json" >/dev/null 2>&1; rc=$?
set -e
t "generic marker alone -> exit 30 rolled-back" "[ $rc -eq 30 ] && [ \"\$(ver)\" = 1.0.0 ] && grep -q 'status: \*\*rolled-back' $T/updates/latest-summary.md"

# (d) same marker during verify but the check now exits 75 -> deferred-provider
plan; install100; rm -f "$T/check-d.count"; set +e
COUNT_FILE="$T/check-d.count" \
FACTORY_UPDATE_PROVIDER_CHECK_CMD="$T/check-first-ok.sh" \
FACTORY_UPDATE_VERIFY_CMD='echo rate_limit_error; exit 1' \
"$FU" apply --check-json "$T/plan.json" >/dev/null 2>&1; rc=$?
set -e
t "generic marker + check 75 -> exit 40 deferred" "[ $rc -eq 40 ] && [ \"\$(ver)\" = 1.0.0 ] && grep -q 'status: \*\*deferred-provider' $T/updates/latest-summary.md"
t "log shows deferred-provider" "grep -q deferred-provider $T/updates/UPDATES-LOG.md"

# (e) ordinary verify failure still rolls back (exit 30)
plan; install100; set +e
FACTORY_UPDATE_PROVIDER_CHECK_CMD=true FACTORY_UPDATE_VERIFY_CMD='echo simulated verify failure; exit 7' "$FU" apply --check-json "$T/plan.json" >/dev/null 2>&1; rc=$?
set -e
t "ordinary verify failure -> exit 30 rolled-back" "[ $rc -eq 30 ] && [ \"\$(ver)\" = 1.0.0 ] && grep -q 'status: \*\*rolled-back' $T/updates/latest-summary.md"

# (f) verify step rc 75 -> provider outage
plan; install100; set +e
FACTORY_UPDATE_PROVIDER_CHECK_CMD=true FACTORY_UPDATE_VERIFY_CMD='exit 75' "$FU" apply --check-json "$T/plan.json" >/dev/null 2>&1; rc=$?
set -e
t "verify rc 75 -> exit 40" "[ $rc -eq 40 ] && [ \"\$(ver)\" = 1.0.0 ] && grep -q 'status: \*\*deferred-provider' $T/updates/latest-summary.md"

# (g) three deferrals in a row escalate once; a following non-deferred run clears the streak
plan; install100; set +e
FACTORY_UPDATE_PROVIDER_CHECK_CMD=true FACTORY_UPDATE_VERIFY_CMD='exit 7' "$FU" apply --check-json "$T/plan.json" >/dev/null 2>&1; rc=$?
set -e
t "non-deferred run clears stale streak" "[ $rc -eq 30 ] && [ ! -e $T/updates/deferred-streak.json ]"

rm -f "$T"/notify/*-update-deferred-repeated.txt 2>/dev/null || true
for i in 1 2 3; do
  plan; install100
  set +e
  FACTORY_UPDATE_PROVIDER_CHECK_CMD="$T/check-75.sh" \
  FACTORY_UPDATE_PROVIDER_WAIT_CMD="$T/wait-75.sh" \
  "$FU" apply --check-json "$T/plan.json" >/dev/null 2>&1; rc=$?
  set -e
  t "deferred run $i -> exit 40" "[ $rc -eq 40 ]"
done
t "three deferrals -> streak count 3" "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"count\"]==3 and d[\"first\"] and d[\"last\"]' \"$T/updates/deferred-streak.json\""
t "three deferrals -> repeated notify" "ls $T/notify/*-update-deferred-repeated.txt >/dev/null 2>&1"
t "repeated notify contains count=3" "grep -q 'count=3' $T/notify/*-update-deferred-repeated.txt"
t "summary has repeated-deferral line" "grep -q -- '- deferred 3 times in a row since ' $T/updates/latest-summary.md"

plan; install100; set +e
FACTORY_UPDATE_PROVIDER_CHECK_CMD=true FACTORY_UPDATE_VERIFY_CMD='exit 7' "$FU" apply --check-json "$T/plan.json" >/dev/null 2>&1; rc=$?
set -e
t "following non-deferred run removes streak" "[ $rc -eq 30 ] && [ ! -e $T/updates/deferred-streak.json ]"

[ $fail -eq 0 ] && echo "test_factory_update_provider: PASS" || { echo "test_factory_update_provider: FAIL"; exit 1; }
