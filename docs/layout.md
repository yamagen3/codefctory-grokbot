# Factory layout (local)

**Decision (closes design.md §8 plugin location):** the factory (DSH plugin, launchers, orchestrator) lives in its **own** git repo. On the original host that checkout is `/workspace/factory`. Scripts take `FACTORY_ROOT` or the directory that contains `bin/`; they do not require that path. Product/target repos live under `targets/` (or a path passed to the orchestrator) and are separate git repos with a local bare `origin`.

OpenCode isolation only bind-mounts the product workspace + `factory-oc` home — **never** the factory checkout. So OpenCode cannot modify the factory plugin even if a product tree somehow nested one.

`tools/agmsg/` is an upstream checkout used for reference/install only — **not** part of the factory commit set (gitignored). Use the installed `agmsg` / `~/.agents/skills/agmsg`.

## Security updates (`bin/factory-update`)

- `factory-update check|apply|daily` — daily security-update batch (see `DECISIONS.md`, 2026-11-05).
- Output: `local/updates/<date>/check-*.json|md`, `apply-*/` (snapshot, verify logs, `result.json`), `local/updates/latest-summary.md`, change log `local/updates/UPDATES-LOG.md`. `local/updates/` is runtime state (gitignored).
- Lock: `local/updates/.lock` (flock; a second run exits 75).
- Verify reuses `factory-doctor`, `factory-step` pong (CC + OpenCode), `bin/factory-oc-leak-check` (P3 14 items), `local/tests/test-cc-allowlist.mjs` + `local/tests/test_cc_fs_allowlist.sh`, `factory-local-dry-run` (acceptance ≥ 10 by default; override with `FACTORY_UPDATE_MIN_ACCEPTANCE`).
- Tests: `local/tests/test_factory_update.sh` (fake npm package in a temp prefix; simulated verify failure → rollback).
- Scheduler: `flock -n "$FACTORY_ROOT/local/updates/.cron.lock" "$FACTORY_ROOT/bin/factory-update" daily` (exit 0 nothing-to-do, 10 updated-ok, 20 needs-approval, 30 rolled-back, 40 deferred-provider — provider outage or rate limit, not a regression; 1 error, 75 locked).

## Usage tracking (`bin/factory-usage`)

- Records: `local/usage/<date>/steps.jsonl` (1 行 1 工程: run_id/target/round/step/provider/started_at/ended_at/duration_ms/input|output|total_tokens/token_source/stop_reason/exit_code/notes)、`agmsg.jsonl`（send / unread poll）、`runs.jsonl` + `local/usage/runs/<run_id>.md`（run 終了サマリ）。`local/usage/` は gitignore。
- Hooks: `factory-step`（全 CC/OpenCode 起動の wall time + tokens）、spec/impl/gate-claude 各 step が `FACTORY_USAGE_STEP`/run id を付与、`factory-run-local` が round と終了時サマリ、`factory-gate-grok record` が grok 待ち時間、plugin の agmsg send が送信回数/時間。
- Report: `factory-usage show|summary|agmsg|balance`（balance = OpenCode Go 残量、CC 残量は対象外）。Tests: `local/tests/test_factory_usage.sh`（モデル呼び出しなし）。
- `bin/factory-oc-provision`（`factory-setup` から呼ぶ）: box 初期化後の OpenCode 隔離復旧（user factory-oc / binary / opencode.json / sudoers / `/var/factory/oc-workspaces`）。冪等。opencode.json は model `opencode-go/deepseek-v4.1-flash`、permission `*` allow、および `providers.opencode-go.models.deepseek-v4.1-flash.settings.reasoningEffort=max`（`…-max` モデル ID は作らない）。`--print-config` はその JSON だけを出す。
- pstack: `factory-pstack-install` recopies the pinned subset. CC does not receive those files unless `apply-cc-allowlist-patch.sh` has spread `pstackQueryOverlay()` into the Agent SDK query. See `docs/pstack-cc.md`.
- OpenCode max: `factory-doctor` fails when the provisioned JSON or the live `/home/factory-oc/.config/opencode/opencode.json` lacks `reasoningEffort=max`. Restore with `factory-oc-provision`.
- SPEC's Claude Code prompt starts with `/goal ` plus a measurable condition, how to prove it, a turn bound, and the brief (`docs/goal.md`). DSH `/goal` is not used. OpenCode IMPL is an ordinary prompt.
- OpenCode reprovision: `factory-oc-provision` writes `reasoningEffort=max` through `factory_oc_write_config`. A max-less file is replaced. `--apply-config <file>` is the same write without sudo.
