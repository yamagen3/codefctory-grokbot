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
