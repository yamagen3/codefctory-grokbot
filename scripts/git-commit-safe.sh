#!/usr/bin/env bash
# Stage paths, secret-scan, commit. Usage: git-commit-safe.sh "msg" [paths...]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MSG="${1:?message}"; shift || true
if [[ $# -gt 0 ]]; then git add "$@"; else git add -A; fi
"$ROOT/scripts/secret-scan.sh"
git -c user.email=factory@localhost -c user.name=factory commit -m "$MSG"
