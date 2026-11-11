#!/usr/bin/env bash
# Shared helpers for factory orchestrator scripts (local + future GitHub).
set -euo pipefail

# Checkout root. FACTORY_ROOT wins when set. Otherwise this file lives in <root>/bin,
# which on the original host is /workspace/factory and elsewhere is the clone path.
if [[ -z "${FACTORY_ROOT:-}" ]]; then
  _factory_common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  FACTORY_ROOT="$(cd "$_factory_common_dir/.." && pwd)"
fi
unset _factory_common_dir
export FACTORY_ROOT
export PATH="${HOME}/.local/bin:${FACTORY_ROOT}/bin:${PATH}"

# DSH headless profile node_modules for the invoking user.
# Original host: HOME=/home/box, so this is /home/box/.dsh/profiles/headless/node_modules.
factory_dsh_profile_nm() {
  if [[ -n "${FACTORY_DSH_PROFILE_NM:-}" ]]; then
    printf '%s\n' "$FACTORY_DSH_PROFILE_NM"
  else
    printf '%s\n' "${HOME}/.dsh/profiles/headless/node_modules"
  fi
}

# Render config/factory.patch.yml for this host.
# Tokens: __FACTORY_ROOT__ and __FACTORY_DSH_NM__.
# Legacy absolute paths are rewritten first, then tokens are expanded.
# The new root may itself start with /workspace/factory (factory.v2 or factory/extra).
# Expanding tokens first would let the legacy pass rewrite those new paths again.
# A path boundary is / or end, not '.': /workspace/factory.v2 is a different directory.
# When the host already is /home/box and /workspace/factory, the text is unchanged.
factory_render_patch() {
  local src="${1:?}" dest="${2:?}"
  local nm
  nm="$(factory_dsh_profile_nm)"
  python3 - "$src" "$dest" "$FACTORY_ROOT" "$nm" <<'PY'
import pathlib, re, sys
src, dest, root, nm = sys.argv[1:]
text = pathlib.Path(src).read_text()

def sub_exact(text, old, new):
    if not old or old == new:
        return text
    return re.sub(re.escape(old) + r"(?![A-Za-z0-9_.-])", lambda _m: new, text)

text = sub_exact(text, "/workspace/factory", root)
text = sub_exact(text, "/home/box/.dsh/profiles/headless/node_modules", nm)
text = text.replace("__FACTORY_ROOT__", root).replace("__FACTORY_DSH_NM__", nm)
pathlib.Path(dest).write_text(text)
PY
}

die() { echo "factory: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null || die "missing command: $1"; }

# Backends / placeholders (never commit secrets):
#   FACTORY_BACKEND=local|github   (default local)
#   FACTORY_GITHUB_TOKEN_GROK  — contents + pull_requests + statuses
#   FACTORY_GITHUB_TOKEN_CC    — statuses only
#   FACTORY_GITHUB_REPO        — owner/name
#   FACTORY_GITHUB_API         — override API base (tests)

round_label() { echo "round-$1"; }

# Normalize a path the caller gave us (relative or absolute) to an absolute
# existing directory. Relative paths otherwise break `cd` + nested git calls
# (e.g. factory-merge with local/work/... failed checkout main).
resolve_repo() {
  local raw="${1:-}"
  [[ -n "$raw" ]] || die "resolve_repo: empty path"
  local abs
  if command -v realpath >/dev/null 2>&1; then
    abs=$(realpath "$raw") || die "resolve_repo: cannot resolve: $raw"
  else
    abs=$(cd "$raw" && pwd) || die "resolve_repo: cannot cd: $raw"
  fi
  [[ -d "$abs" ]] || die "resolve_repo: not a directory: $abs"
  printf '%s\n' "$abs"
}

# OpenCode config for the shared factory-oc home (and, via seed_oc_home, new slot homes).
# Max is settings.reasoningEffort on opencode-go/deepseek-v4.1-flash. It is an effort
# value from models.dev (low|high|max), not a model id and not a root #variant
# (https://opencode.ai/docs/config/ : root model does not retain #variant;
# https://opencode.ai/docs/models/ : providers.<id>.models.<id>.settings.reasoningEffort).
# Other FACTORY_OC_MODEL values keep the previous model+permission document: max was
# checked only for this catalog model.
factory_oc_opencode_json() {
  local model="${1:-${FACTORY_OC_MODEL:-opencode-go/deepseek-v4.1-flash}}"
  if [[ "$model" == "opencode-go/deepseek-v4.1-flash" ]]; then
    cat <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "opencode-go/deepseek-v4.1-flash",
  "permission": { "*": "allow" },
  "providers": {
    "opencode-go": {
      "models": {
        "deepseek-v4.1-flash": {
          "settings": {
            "reasoningEffort": "max"
          }
        }
      }
    }
  }
}
EOF
  else
    printf '{\n  "$schema": "https://opencode.ai/config.json",\n  "model": "%s",\n  "permission": { "*": "allow" }\n}\n' "$model"
  fi
}

# Exit 0 when stdin is the factory OpenCode document with reasoningEffort=max.
# Prints one reason on failure. Does not accept a missing field.
factory_oc_config_problems() {
  python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    doc = json.loads(raw)
except Exception as exc:
    print(f"opencode.json is not JSON: {exc}")
    raise SystemExit(1)
problems = []
model = doc.get("model")
if model != "opencode-go/deepseek-v4.1-flash":
    problems.append(f"model is {model!r}, want opencode-go/deepseek-v4.1-flash")
if "deepseek-v4.1-flash-max" in raw:
    problems.append("document contains a -max model id")
def dig(obj, *keys):
    cur = obj
    for key in keys:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(key)
    return cur
effort = dig(doc, "providers", "opencode-go", "models", "deepseek-v4.1-flash", "settings", "reasoningEffort")
if effort != "max":
    problems.append(f"reasoningEffort is {effort!r}, want max")
if problems:
    print("; ".join(problems))
    raise SystemExit(1)
'
}

# Compare-and-write the provisioned OpenCode document.
# mode=file writes directly; mode=sudo is the box path (root-owned home).
# Prints "wrote" or "unchanged". A file that lost max is replaced with the
# document that contains reasoningEffort=max, so reprovision restores it.
factory_oc_write_config() {
  local dest="${1:-}" mode="${2:-file}"
  local model="${FACTORY_OC_MODEL:-opencode-go/deepseek-v4.1-flash}"
  local want current
  [[ -n "$dest" ]] || die "factory_oc_write_config: dest required"
  want=$(factory_oc_opencode_json "$model")
  if [[ "$mode" == sudo ]]; then
    current=$(sudo -n cat "$dest" 2>/dev/null || true)
  else
    current=$(cat "$dest" 2>/dev/null || true)
  fi
  if [[ "$current" == "$want" ]]; then
    printf 'unchanged\n'
    return 0
  fi
  if [[ "$mode" == sudo ]]; then
    printf '%s' "$want" | sudo -n tee "$dest" >/dev/null
    sudo -n chown factory-oc:factory-oc "$dest"
    sudo -n chmod 600 "$dest"
  else
    mkdir -p "$(dirname "$dest")"
    printf '%s' "$want" > "$dest"
  fi
  printf 'wrote\n'
}
