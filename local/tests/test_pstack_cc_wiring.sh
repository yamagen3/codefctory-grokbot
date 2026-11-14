#!/usr/bin/env bash
# Offline wiring: CC pins, the claude -p argv, the hook settings, and the stage bootstrap.
# Does not start Claude or OpenCode and does not use credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "test_pstack_cc_wiring: FAIL $*" >&2; exit 1; }

grep -q '79b36d9b53a53c78e5ec26bf6ce7dade76686c87' "$ROOT/bin/factory-pstack-install" \
  || fail "pstack pin changed"
grep -q 'plugin marketplace' "$ROOT/bin/factory-pstack-install" && fail "installer must not add the marketplace plugin"
CFG="$ROOT/config/claude-code.json"
python3 - "$CFG" <<'PY' || fail "config/claude-code.json pins changed"
import json, sys
c = json.load(open(sys.argv[1]))
assert c["model"] == "claude-opus-5-5", c
assert c["effort"] == "xhigh", c
assert c["permission_mode"] == "acceptEdits", c
assert c["setting_sources"] == "user", c
assert "AskUserQuestion" in c["disallowed_tools"], c
PY
grep -q 'opencode-go/deepseek-v4.1-flash' "$ROOT/bin/factory-common.sh" || fail "OC model default changed"
grep -q 'reasoningEffort": "max"' "$ROOT/bin/factory-common.sh" || fail "OC max effort missing"
grep -q 'auto-apply only small patch/security fixes' "$ROOT/DECISIONS.md" || fail "security-update policy text missing"

# The argv and hook settings the runner builds (no process is started).
(cd "$ROOT" && python3 - <<'PY') || fail "runner argv/settings"
import sys
sys.path.insert(0, "lib")
import factory_step as fs
cfg = fs.load_cc_config()
argv = fs.cc_argv("claude", cfg, "/goal x", "/tmp/s.json", "/tmp/a.md", "sid")
def val(flag):
    return argv[argv.index(flag) + 1]
assert argv[:3] == ["claude", "-p", "/goal x"], argv
assert val("--model") == "claude-opus-5-5" and val("--effort") == "xhigh", argv
assert val("--permission-mode") == "acceptEdits" and val("--permission-prompts") == "none", argv
assert val("--setting-sources") == "user" and "--strict-mcp-config" in argv, argv
assert val("--append-system-prompt-file") == "/tmp/a.md" and val("--session-id") == "sid", argv
assert "bypassPermissions" not in argv and "--dangerously-skip-permissions" not in argv, argv
assert "--bare" not in argv, "bare mode ignores CLAUDE_CODE_OAUTH_TOKEN"
s = fs.cc_settings("/r/lib/cc/hook.mjs")["hooks"]
assert s["PreToolUse"][0]["matcher"] == "*" and s["PreToolUse"][0]["hooks"][0]["command"].endswith("hook.mjs pretooluse || exit 2"), s
assert s["Stop"][0]["hooks"][0]["command"].endswith("hook.mjs stop"), s
import os
os.environ.update({"ANTHROPIC_API_KEY": "x", "OPENCODE_GO_KEY": "y", "FACTORY_CC_OAUTH_TOKEN": "t", "CLAUDE_CODE_OAUTH_TOKEN": ""})
env = fs.cc_child_env(cfg, "/w")
assert "ANTHROPIC_API_KEY" not in env and "OPENCODE_GO_KEY" not in env and "FACTORY_CC_OAUTH_TOKEN" not in env, sorted(env)
assert env["CLAUDE_CODE_OAUTH_TOKEN"] == "t" and env["CLAUDE_CODE_EFFORT_LEVEL"] == "xhigh", "token/effort"
assert "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB" not in env and env["DISABLE_AUTOUPDATER"] == "1", "scrub/autoupdate"
print("runner argv ok")
PY

echo "=== hook command fails closed; a stray package.json does not break it ==="
H="$(mktemp -d /tmp/cc-hook-wiring-XXXXXX)"
mkdir -p "$H/lib/cc" && cp "$ROOT"/lib/cc/{hook.mjs,allowlist.js,package.json} "$H/lib/cc/"
: > "$H/package.json"   # empty, invalid: seen in a PC checkout on 2026-11-14
hook_cmd() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1] + "/lib"); import factory_step as fs; print(fs.cc_settings(sys.argv[2])["hooks"]["PreToolUse"][0]["hooks"][0]["command"])' "$ROOT" "$1"; }
IN='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},"cwd":"/tmp"}'
out=$(printf '%s' "$IN" | FACTORY_CC_STEP=spec FACTORY_CC_CWD=/tmp sh -c "$(hook_cmd "$H/lib/cc/hook.mjs")") || { echo "test_pstack_cc_wiring: FAIL hook crashed with a stray package.json" >&2; exit 1; }
grep -q '"permissionDecision"' <<<"$out" || { echo "test_pstack_cc_wiring: FAIL no decision: $out" >&2; exit 1; }
printf 'throw new Error("boom")\n' > "$H/lib/cc/hook.mjs"
set +e
printf '%s' "$IN" | FACTORY_CC_STEP=spec sh -c "$(hook_cmd "$H/lib/cc/hook.mjs")" >/dev/null 2>&1
hec=$?
set -e
rm -rf "$H"
[[ "$hec" -eq 2 ]] || { echo "test_pstack_cc_wiring: FAIL crashed hook exited $hec, want 2 (blocks the tool)" >&2; exit 1; }

node "$ROOT/local/tests/test_pstack_cc_session.mjs"
echo "test_pstack_cc_wiring: PASS"
