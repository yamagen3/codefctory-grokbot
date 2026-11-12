#!/usr/bin/env bash
# Offline docs regression: extensibility proposal exists, has the required
# sections, and is linked from README.md. No code, model, or network calls.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOC="$ROOT/docs/extensibility.md"
README="$ROOT/README.md"

fail() { echo "test_docs_extensibility: FAIL $*" >&2; exit 1; }

[[ -f "$DOC" ]] || fail "missing docs/extensibility.md"

grep -qE '^## 4\. Provider adapter contract \(proposal\)' "$DOC" \
  || fail "missing section 4 heading"
grep -qE '^## 5\. Pipeline descriptor \(proposal\)' "$DOC" \
  || fail "missing section 5 heading"
grep -qE '^## 6\. Non-code pipelines \(proposal\)' "$DOC" \
  || fail "missing section 6 heading"

grep -qi 'proposal' "$DOC" || fail "document never says proposal"

[[ -f "$README" ]] || fail "missing README.md"
grep -Eq '\[[^]]+\]\(docs/extensibility\.md\)' "$README" \
  || fail "README.md does not link to docs/extensibility.md"

echo "test_docs_extensibility: PASS"
