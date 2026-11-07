#!/usr/bin/env bash
# Fail if staged (or given) paths look like secrets. Never prints secret values.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
paths=("$@")
if [[ ${#paths[@]} -eq 0 ]]; then
  mapfile -t paths < <(git diff --cached --name-only --diff-filter=ACMR)
fi
[[ ${#paths[@]} -eq 0 ]] && exit 0
fail=0
for f in "${paths[@]}"; do
  [[ -f "$f" ]] || continue
  case "$f" in
    *.md|*.yml|*.yaml|*.json|*.js|*.sh|*.py|*.toml|*.txt|*.css|*.html) ;;
    *) continue ;;
  esac
  # Pattern hits (content length-gated to avoid huge binaries)
  if grep -EIq \
    -e 'oc_[A-Za-z0-9_-]{20,}' \
    -e 'sk-[A-Za-z0-9_-]{20,}' \
    -e 'ghp_[A-Za-z0-9]{20,}' \
    -e 'github_pat_[A-Za-z0-9_]{20,}' \
    -e 'CLAUDE_CODE_OAUTH_TOKEN[[:space:]]*=[[:space:]]*[^[:space:]]+' \
    -e 'OPENCODE_GO_KEY[[:space:]]*=[[:space:]]*[^[:space:]]+' \
    -e 'DEEPSEEK_API_KEY[[:space:]]*=[[:space:]]*[^[:space:]]+' \
    -e '-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----' \
    -- "$f"; then
    echo "secret-scan: BLOCKED suspicious pattern in $f" >&2
    fail=1
  fi
done
exit "$fail"
