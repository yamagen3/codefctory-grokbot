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

# Claude Code's built-in /goal for the SPEC step. The condition is only the
# first line: the docs cap it at 4,000 characters
# (https://code.claude.com/docs/en/goal). The brief and the rest of the SPEC
# instructions follow that line, in full, so a long brief is not truncated and
# is not stuffed into the condition. DSH /goal is not used.
factory_cc_spec_prompt() {
  local brief="${1:-}" pkg="${2:-unknown}" turns="${FACTORY_CC_GOAL_TURNS:-12}"
  local condition prompt
  [[ -n "$brief" ]] || die "factory_cc_spec_prompt: brief required"
  [[ "$turns" =~ ^[1-9][0-9]*$ ]] || die "factory_cc_spec_prompt: turn bound must be a positive integer"
  condition="/goal Freeze spec/PRODUCT.md, tests/acceptance, spec/OPEN_QUESTIONS.md, and spec/IMPL_STRATEGY.md whose first line is parallel: N with N from 1 to 4. Prove it by quoting those in the final reply. Do not implement src/. Or stop after ${turns} turns."
  [[ "${#condition}" -le 4000 ]] || die "factory_cc_spec_prompt: /goal condition is ${#condition} characters; Claude Code allows 4000"
  prompt="${condition}

You are the factory SPEC step. Working directory is the product repo."
  cat <<EOF
${prompt}

Create or update ONLY under spec/ and tests/acceptance/:
- spec/PRODUCT.md — concise, testable product spec (Python stdlib only unless the brief explicitly allows deps; target Python 3.12+). Include CLI invocation, I/O, errors, and constraints.
- tests/acceptance/ — real unittest acceptance tests that encode frozen behavior (may fail until implemented). Prefer fixtures under tests/acceptance/fixtures/ with no secrets.
- spec/OPEN_QUESTIONS.md — open questions for the human (bullet list). If none, write: None.
- spec/IMPL_STRATEGY.md — decide OpenCode IMPL parallelism for this run. First line MUST be machine-readable:
    parallel: <N>
  where N is an integer 1..4 (cap 4). Below that, write a short Japanese and/or English rationale.

  Parallel-first guidance (you decide N; humans do not set it via env):
  - Prefer N≥2 when the work can usefully diverge (multiple approaches, independent modules, flaky single-shot risk).
  - Use N=1 only when the change is tiny/sequential or parallelism would waste OpenCode Go quota without benefit.
  - Be concrete about why this N fits THIS product/spec.

Do not implement the product under src/ beyond what already exists as a scaffold. Do not modify .github/. Keep changes minimal.
Package/CLI name hint from pyproject: ${pkg}
Brief: ${brief}
EOF
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
