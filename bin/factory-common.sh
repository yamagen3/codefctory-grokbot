#!/usr/bin/env bash
# Shared helpers for factory orchestrator scripts (local + future GitHub).
set -euo pipefail

FACTORY_ROOT="${FACTORY_ROOT:-/workspace/factory}"
export PATH="${HOME}/.local/bin:${FACTORY_ROOT}/bin:${PATH}"

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
