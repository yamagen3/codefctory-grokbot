#!/usr/bin/env bash
# A checkout that is not /workspace/factory, with HOME that is not /home/box,
# still resolves its own paths, keeps CC pins, and passes the no-secret scan.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "test_fresh_paths: FAIL $*" >&2; exit 1; }

grep -q '@anthropic-ai/claude-code@$CC_PIN' "$ROOT/bin/factory-setup" || fail "factory-setup does not install the pinned claude CLI"
grep -q 'failed to load or run' "$ROOT/bin/factory-step" || fail "factory-step does not fail a step that did not run"

# local/tests must not be gitignored (doctor runs two of these files).
if git -C "$ROOT" check-ignore -q -- local/tests/test_github_backend.py \
  || git -C "$ROOT" check-ignore -q -- local/tests/test-cc-allowlist.mjs; then
  fail "local/tests is gitignored"
fi

# The runner and hook derive every path from the checkout (no rendered patch, no ~/.dsh).
HOME_TMP="$(mktemp -d /tmp/factory-home-XXXXXX)"
trap 'rm -rf "$HOME_TMP" ${CLONE:+"$CLONE"}' EXIT
(cd /tmp && env -u FACTORY_ROOT HOME="$HOME_TMP" python3 - "$ROOT" <<'PY') || fail "runner paths do not follow the checkout"
import sys
root = sys.argv[1]
sys.path.insert(0, root + "/lib")
import factory_step as fs
assert str(fs.ROOT) == root, (fs.ROOT, root)
cfg = fs.load_cc_config()
assert cfg["model"] == "claude-opus-5-5" and cfg["effort"] == "xhigh", cfg
hook = fs.cc_settings(fs.ROOT / "lib/cc/hook.mjs")["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
assert root + "/lib/cc/hook.mjs" in hook, hook
for bad in ("/home/box", ".dsh"):
    assert bad not in hook, hook
PY
if grep -rqE '/home/box|\.dsh/profiles' "$ROOT/lib/factory_step.py" "$ROOT/lib/cc" "$ROOT/bin/factory-step"; then
  fail "runner still hardcodes /home/box or the DSH profile"
fi

# Common derives the checkout when FACTORY_ROOT is unset.
derived="$(env -u FACTORY_ROOT bash -c 'source "'"$ROOT"'/bin/factory-common.sh"; printf %s "$FACTORY_ROOT"')"
[[ "$derived" == "$ROOT" ]] || fail "FACTORY_ROOT derived as $derived, want $ROOT"

# Secret scan of this tree. The pre-existing test filename
# test_oc_reprovision_keeps_max matches the oc_<20+> token rule; that identifier
# is not a credential. Any other hit fails.
mapfile -t files < <(git -C "$ROOT" ls-files)
scan_out="$(mktemp)"
set +e
"$ROOT/scripts/secret-scan.sh" "${files[@]}" >"$scan_out" 2>&1
scan_ec=$?
set -e
if [[ "$scan_ec" -ne 0 ]]; then
  mapfile -t blocked < <(sed -n 's/^secret-scan: BLOCKED suspicious pattern in //p' "$scan_out")
  [[ ${#blocked[@]} -gt 0 ]] || fail "secret-scan failed: $(cat "$scan_out")"
  for rel in "${blocked[@]}"; do
    scrubbed="$(mktemp)"
    # The test filename contains oc_ + a long identifier. Scrub that token and rescan.
    sed 's/oc_reprovision_keeps_max/oc_testname/g' "$ROOT/$rel" > "$scrubbed"
    if grep -EIq \
      -e 'oc_[A-Za-z0-9_-]{20,}' \
      -e 'sk-[A-Za-z0-9_-]{20,}' \
      -e 'ghp_[A-Za-z0-9]{20,}' \
      -e 'github_pat_[A-Za-z0-9_]{20,}' \
      -e 'CLAUDE_CODE_OAUTH_TOKEN[[:space:]]*=[[:space:]]*[^[:space:]]+' \
      -e 'OPENCODE_GO_KEY[[:space:]]*=[[:space:]]*[^[:space:]]+' \
      -e 'DEEPSEEK_API_KEY[[:space:]]*=[[:space:]]*[^[:space:]]+' \
      -e '-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----' \
      -- "$scrubbed"; then
      rm -f "$scrubbed"
      fail "secret-scan hit in $rel beyond the known test filename"
    fi
    rm -f "$scrubbed"
  done
fi
rm -f "$scan_out"

if [[ -n "${FACTORY_FRESH_INNER:-}" ]]; then
  echo "test_fresh_paths: PASS (inner)"
  exit 0
fi

# Fresh tree at a non-default path, non-box HOME, no-secret checks only.
# rsync the worktree (including uncommitted fixes) and make a new git repo so
# this does not depend on the changes already being committed.
CLONE="$(mktemp -d /tmp/factory-clone-XXXXXX)"
mkdir -p "$CLONE/repo"
tar -C "$ROOT" \
  --exclude .git --exclude node_modules --exclude dry-runs --exclude local/work \
  --exclude local/usage --exclude local/logs --exclude local/origin \
  -cf - . | tar -C "$CLONE/repo" -xf -
git -C "$CLONE/repo" init -b main >/dev/null
git -C "$CLONE/repo" add -A
git -C "$CLONE/repo" -c user.email=factory@localhost -c user.name=factory commit -m "fresh tree" >/dev/null
env -u FACTORY_ROOT HOME="$HOME_TMP" FACTORY_FRESH_INNER=1 bash "$CLONE/repo/local/tests/test_fresh_paths.sh"
env -u FACTORY_ROOT HOME="$HOME_TMP" bash "$CLONE/repo/local/tests/test_resolve_repo.sh" >/tmp/fresh-resolve.txt
grep -q 'OK resolve_repo' /tmp/fresh-resolve.txt || fail "fresh clone resolve_repo"
env -u FACTORY_ROOT HOME="$HOME_TMP" bash "$CLONE/repo/local/tests/test_gate_grok_full_diff.sh" >/tmp/fresh-gate.txt
grep -q 'OK gate-grok' /tmp/fresh-gate.txt || fail "fresh clone gate diff"
env -u FACTORY_ROOT HOME="$HOME_TMP" python3 "$CLONE/repo/local/tests/test_github_backend.py" >/tmp/fresh-gh.txt
env -u FACTORY_ROOT HOME="$HOME_TMP" node "$CLONE/repo/local/tests/test-cc-allowlist.mjs" >/tmp/fresh-cc.txt
echo "test_fresh_paths: PASS"
