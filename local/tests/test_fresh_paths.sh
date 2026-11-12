#!/usr/bin/env bash
# A checkout that is not /workspace/factory, with HOME that is not /home/box,
# still renders patch paths, keeps CC pins, and passes the no-secret scan.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "test_fresh_paths: FAIL $*" >&2; exit 1; }

grep -q 'npm ci --omit=dev' "$ROOT/bin/factory-setup" || fail "factory-setup does not npm ci plugin deps"
grep -q 'failed to load or run' "$ROOT/bin/factory-step" || fail "factory-step does not fail a plugin that did not run"

# local/tests must not be gitignored (doctor runs two of these files).
if git -C "$ROOT" check-ignore -q -- local/tests/test_github_backend.py \
  || git -C "$ROOT" check-ignore -q -- local/tests/test-cc-allowlist.mjs; then
  fail "local/tests is gitignored"
fi

# $1 home, $2 logical FACTORY_ROOT written into the patch, $3 dest file.
# The yaml and helper always come from this checkout ($ROOT).
render_one() {
  local home="$1" fact_root="$2" dest="$3"
  env -u FACTORY_DSH_PROFILE_NM HOME="$home" FACTORY_ROOT="$fact_root" \
    bash -c 'source "$1/bin/factory-common.sh"; factory_render_patch "$1/config/factory.patch.yml" "$2"' \
    bash "$ROOT" "$dest"
}

# This tree, with a non-box HOME.
HOME_TMP="$(mktemp -d /tmp/factory-home-XXXXXX)"
RENDER="$(mktemp /tmp/factory-patch-render-XXXXXX.yml)"
trap 'rm -rf "$HOME_TMP" "$RENDER" ${CLONE:+"$CLONE"}' EXIT
render_one "$HOME_TMP" "$ROOT" "$RENDER"
grep -q "$HOME_TMP/.dsh/profiles/headless/node_modules/@deepseek-ai/dsh-subagent-claude-code/lib/index.js" "$RENDER" \
  || fail "rendered patch did not use HOME for the CC plugin"
grep -q "$ROOT/plugin/index.js" "$RENDER" || fail "rendered patch did not use the checkout for the orchestrator"
grep -q "$ROOT/bin/opencode-acp-isolated" "$RENDER" || fail "rendered patch did not use the checkout for the launcher"
grep -q 'model: claude-opus-5-5' "$RENDER" || fail "CC model pin dropped"
grep -q "CLAUDE_CODE_EFFORT_LEVEL: 'xhigh'" "$RENDER" || fail "CC effort pin dropped"
if [[ "$HOME_TMP" != /home/box ]]; then
  grep -q '/home/box' "$RENDER" && fail "rendered patch still contains /home/box"
fi
if [[ "$ROOT" != /workspace/factory ]]; then
  grep -q '/workspace/factory/' "$RENDER" && fail "rendered patch still contains /workspace/factory"
fi

# Original host values render back to the historical paths.
ORIG="$(mktemp /tmp/factory-patch-orig-XXXXXX.yml)"
render_one /home/box /workspace/factory "$ORIG"
grep -q '/home/box/.dsh/profiles/headless/node_modules/@deepseek-ai/dsh-subagent-claude-code/lib/index.js' "$ORIG" \
  || fail "original host HOME did not render the historical DSH path"
grep -q '/workspace/factory/plugin/index.js' "$ORIG" || fail "original host root did not render the historical plugin path"
rm -f "$ORIG"

# A root that starts with the legacy prefix must not be rewritten a second time.
DOT="$(mktemp /tmp/factory-patch-dot-XXXXXX.yml)"
render_one /home/factory /workspace/factory.v2 "$DOT"
grep -Fq '/workspace/factory.v2/plugin/index.js' "$DOT" || fail "dot-suffix root missing"
grep -Fq '/workspace/factory.v2/bin/opencode-acp-isolated' "$DOT" || fail "dot-suffix launcher missing"
grep -Fq '/workspace/factory.v2.v2' "$DOT" && fail "dot-suffix root was rewritten twice"
rm -f "$DOT"
NEST="$(mktemp /tmp/factory-patch-nest-XXXXXX.yml)"
render_one /home/factory /workspace/factory/extra "$NEST"
grep -Fq '/workspace/factory/extra/plugin/index.js' "$NEST" || fail "nested root missing"
grep -Fq '/workspace/factory/extra/extra' "$NEST" && fail "nested root was rewritten twice"
rm -f "$NEST"
# A file that still has the old literals is rewritten once, including a dot-suffix root.
LEG_SRC="$(mktemp /tmp/factory-patch-leg-XXXXXX.yml)"
LEG="$(mktemp /tmp/factory-patch-legout-XXXXXX.yml)"
printf '%s\n' "plugin: /workspace/factory/plugin/index.js" "nm: /home/box/.dsh/profiles/headless/node_modules/pkg" > "$LEG_SRC"
env -u FACTORY_DSH_PROFILE_NM HOME=/home/factory FACTORY_ROOT=/workspace/factory.v2 \
  bash -c 'source "$1/bin/factory-common.sh"; factory_render_patch "$2" "$3"' \
  bash "$ROOT" "$LEG_SRC" "$LEG"
grep -Fq 'plugin: /workspace/factory.v2/plugin/index.js' "$LEG" || fail "legacy literal was not rewritten once"
grep -Fq '/workspace/factory.v2.v2' "$LEG" && fail "legacy literal dot-suffix was rewritten twice"
grep -Fq 'nm: /home/factory/.dsh/profiles/headless/node_modules/pkg' "$LEG" || fail "legacy DSH literal was not rewritten"
rm -f "$LEG_SRC" "$LEG"

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
