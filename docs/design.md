# コードファクトリー設計 v0（実装反映版）

状態: P0〜P5 を **ローカル模擬**まで完了（2026-11-04）。GitHub 実リポジトリへの push / 保護設定は未着手（ユーザー作業）。

## 0. 前提: 実行環境を最新に保つ / OpenCode は parallel-first

factory は実行環境を最新に保つ。Claude Code CLI、OpenCode と関連ツールは、必要なモデルや機能（例: CC の `claude-opus-5-5` + effort `xhigh`）が常に使えるよう更新する。更新は必ず `factory-update` のスナップショット → 検証 → 自動ロールバック経路を通す。日次バッチは従来どおりセキュリティ修正と patch/minor を自動適用し、本体（Claude Code CLI / OpenCode / major）の更新は「重大脆弱性」または「必要なモデル・機能のために最新化が要る」ときに承認つきで行う（`factory-update apply --approve`）。

**OpenCode IMPL は parallel-first。** 並列度 N は人間が env で毎回いじるものではなく、SPEC 工程の Claude Code が `spec/IMPL_STRATEGY.md`（`parallel: N`）で決める。並列が効くところは前提として押し、N=1 は小さな逐次変更など本当に無駄なときだけ。

**OpenCode の max は努力値であり、モデル ID ではない。** モデルは `opencode-go/deepseek-v4.1-flash` のまま。`factory-oc-provision` が共有 `opencode.json` に次を書く。

```json
"providers": {
  "opencode-go": {
    "models": {
      "deepseek-v4.1-flash": {
        "settings": { "reasoningEffort": "max" }
      }
    }
  }
}
```

`bin/factory-impl-step` の `seed_oc_home` がこの共有 `.config/opencode/` を新規スロット HOME へコピーする。再プロビジョンはファイル全体をこの内容で揃えるので、ランタイムだけに足した max は再構築で消えない。すでに存在するスロット HOME は作成時のスナップショットで、この変更では書き換えない。`FACTORY_OC_MODEL` で別モデルに上書きしたときは max を付けない（カタログ確認は上記モデルだけ）。`permission: {"*":"allow"}` とセキュリティ更新方針は変えない。

根拠（2026-11-07）: [config schema](https://opencode.ai/config.json) の `providers` → `Config.Model.Settings`（`reasoningEffort` は追加プロパティ。root の非推奨 `provider` は使わない）。[config](https://opencode.ai/docs/config/) と [models](https://opencode.ai/docs/models/) は root `model` が `#variant` を保持しないと明記し、努力値は `providers.<id>.models.<id>.settings.reasoningEffort` に置く。[models.dev/api.json](https://models.dev/api.json) の `opencode-go` / `deepseek-v4.1-flash` の `reasoning_options` は effort `low` / `high` / `max`。同プロバイダに `deepseek-v4.1-flash-max` は無い。

**SPEC の CC プロンプトは Claude Code の `/goal <条件>`。** `claude -p` の 1 回の起動で goal ループが完了まで回る。条件には証明の仕方と `or stop after N turns` と brief を入れる。工場全体の最終判定は Grok の gate のまま。詳細は `docs/goal.md`。

**OpenCode の max が実行時ファイルから消えたら doctor は失敗する。** `factory-oc-provision --print-config` と、factory-oc がいるときの `/home/factory-oc/.config/opencode/opencode.json` の両方で `reasoningEffort=max` を要求する。欠落は既定扱いしない。Claude Code CLI のピンは `config/claude-code.json`（`2.1.319`）。

**pstack は手法であり、モデルではない。** スキルファイルを `~/.claude/skills` に置くだけでは SPEC/gate のプロンプトに本文は入らない。runner は `--setting-sources user` でユーザー技能だけを読ませ、SPEC と gate だけが段階ごとの SKILL.md 本文を `--append-system-prompt-file` で受け取る。poteto-mode の SessionStart 自動ルート（サブエージェントとモデル振分）は使わない。詳細は `docs/pstack-cc.md`。CC は `claude-opus-5-5` / `xhigh`、OpenCode は Flash max、並列度は CC の `spec/IMPL_STRATEGY.md` のまま。

## 1. 構成

```text
あなた
  | 依頼 / 本番の仕様承認 / 停止時の判断
  v
Grok Bot (クラウド box)   全体管理、受入れ確認、gate/grok、マージ
  | 工程ごとに bin/factory-step を起動
  v
lib/factory_step.py       薄いランナー（モデルなし）: env 分離、timeout、usage、step end
  ├ claude -p (標準 CLI)   仕様、受入れテスト、gate/claude（PreToolUse フックで allowlist）
  └ sudo → bwrap → opencode run (隔離)  実装（OpenCode Go / DeepSeek）

agmsg / local/logs        進捗の参考情報（判定根拠にしない）
題材リポ（local bare origin → 将来 GitHub 公開）  成果物と判定の正本
factory リポ（/workspace/factory）  オーケストレータ本体（OpenCode から不可視）
```

## 2. 決定事項

| # | 論点 | 決定 |
|---|---|---|
| Q1, Q8 | 実行場所 | Grok Bot のクラウド box（ローカル PC の WSL でも同じ checkout が動く） |
| Q2, Q14 | 最初の対象 | 新規 CSV→Markdown 表 CLI（stdlib のみ、Python 3.12） |
| Q3 | 第二ゲート | Grok（`factory-gate-grok` + レビュー束）。通れば自動マージ |
| Q4 | 差し戻し | 全ゲート合格のときだけマージ。実装は最大 3 周。超えたら `factory-notify` |
| Q5 | 権限 | OpenCode は factory-oc + bwrap。渡すのは `OPENCODE_API_KEY`（Go）のみ |
| Q6 | 進捗管理 | agmsg（任意）+ 常時 `local/logs/agmsg-progress.log`。判定根拠にしない |
| Q7 | 起動の流れ | Grok が管理し、`factory-step` が標準 `claude` / `opencode run` を直接起動する（§11。DSH は 2026-11-14 に撤去） |
| Q9 | Git リモート | 本番は GitHub Free 公開リポ。**現在は local bare origin**（`FACTORY_BACKEND=local`） |
| Q10 | 仕様の承認 | 本番は人間。**ローカルは自動承認**（`spec/<id>` タグ、`DECISIONS.md`） |
| Q11 | CC の認証 | `CLAUDE_CODE_OAUTH_TOKEN` |
| Q12 | 実行単位 | 工程ごとに CLI を 1 回起動（`claude -p` / `opencode run`） |
| Q13 | 第一ゲート | CC が受入れを先に書く。実行は ci。照合は `gate/claude` |
| — | factory の置き場所 | **題材と分離**（`docs/layout.md`）。OpenCode の bwrap は factory をマウントしない |
| — | OpenCode モデル | 有料 OpenCode Go。`opencode-go/deepseek-v4.1-flash`。Privacy Regions=**Global** 必須。推論の最大は別モデル ID ではなく `providers.opencode-go.models.deepseek-v4.1-flash.settings.reasoningEffort=max` |
| — | API キー名 | box の `OPENCODE_GO_KEY` → 子の `OPENCODE_API_KEY`。`DEEPSEEK_API_KEY` は未使用 |
| — | バックエンド切替 | `FACTORY_BACKEND=local\|github`（既定 local）。github はトークンプレースホルダ |

## 3. 流れ（ローカル実装）

1. `factory-run-local <id>` または個別ステップを起動する。
2. **SPEC（CC）:** `factory-spec-step`。FS allowlist で `spec/` と `tests/acceptance/` のみ書込可。あわせて `spec/IMPL_STRATEGY.md`（`parallel: N`）で IMPL 並列度を CC が決める。
3. **仕様固定（ローカル自動承認）:** `spec/<id>` タグ。
4. 周回（最大 3）:
   1. **IMPL（OpenCode）:** 隔離ワークスペース → `factory-patch-extract`（保護パス・バイナリ・symlink 拒否）→ クリーン clone に適用。

### IMPL parallel OpenCode（CC 決定・parallel-first）

- **誰が N を決めるか:** SPEC の Claude Code が `spec/IMPL_STRATEGY.md` に `parallel: N`（1..4）を書く。人間が日常的に env で選ぶ前提ではない。
- **解決順（`factory-impl-step`）:**
  1. `FACTORY_OC_PARALLEL` がセットされていればそれを使う（試験・緊急上書き。stderr に override ログ）。
  2. なければ `spec/IMPL_STRATEGY.md` の `parallel: N`。
  3. 欠落・不正なら **既定 N=2**（parallel-first）し stderr に警告。
  4. いずれも clamp 1..4。要約 JSON に `parallel_source`（`env` | `spec` | `default`）を記録。
- `factory-impl-step` がスロットごとに `impl-<id>-<pid>-sN` ワークスペースと `/var/factory/oc-homes/...-sN`（`FACTORY_OC_HOME`）を用意し、N 個の `factory-step`（OpenCode ACP プロセス）を並列起動する。
- 各スロット: patch extract → 一時 clone に適用 → acceptance 合格数を採点。勝者は **OC exit 0 優先 → acceptance 合格数が多い → 非空 patch → 低いスロット番号**。勝者 patch だけを本リポへ適用・コミット。全スロット空/失敗なら非ゼロ終了（黙って空コミットしない）。
- `opencode-acp-isolated` は WS の realpath が `/var/factory/oc-workspaces/` 配下であることを強制。`FACTORY_OC_HOME` 設定時はその realpath が `/var/factory/oc-homes/` か当該 WS 配下のときだけ共有 `/home/factory-oc` の代わりに bind（バイナリは共有を ro-bind）。未設定時は共有 home（後方互換）。
- 結果 JSON はスロット別（`local/logs/impl-<id>-*-sN.json`）。要約は `local/logs/impl-<id>-parallel.json`（`parallel` + `parallel_source`）。

   2. **guard / ci:** 同一ロジックをローカル script と workflow 雛形で共有。
   3. **gate/claude（CC）:** 読取専用 FS。statuses に記録。
   4. **gate/grok:** レビュー束を書き、Grok が `factory-gate-grok record`（テストは stub）。
5. 4 チェックが head SHA で success なら `factory-merge`（local git または将来 GH merge API）。

## 4. main の必須チェック

| チェック | 記録者 | 内容 |
|---|---|---|
| `guard` | `factory-guard`（将来 Actions） | `spec/`・`tests/acceptance/`・`.github/` が `spec/<id>` から変わっていたら不合格 |
| `ci` | `factory-ci`（Python 3.12） | unit + acceptance |
| `gate/claude` | CC | 差分と仕様の照合 |
| `gate/grok` | Grok | 独立レビュー（束 + record） |

- コミット SHA ごとに `factory-status`（local JSON / 将来 GitHub Statuses API）。
- 周回は `factory-labels`（`round-N`）。

## 5. 認証情報

| 持ち主 | 持つもの | 持たないもの |
|---|---|---|
| OpenCode | `OPENCODE_API_KEY`（Go）のみ | Git トークン、CC / Grok 認証 |
| CC | `CLAUDE_CODE_OAUTH_TOKEN`、（将来）statuses のみの GH トークン | push / マージ |
| factory-step ランナー | 子へ渡す値だけ（スクラブ後） | 管理権限トークンを常駐させない |
| Grok | （将来）題材限定 PAT（contents / pull_requests / statuses） | Administration |

- OpenCode 作業領域に push 可能な `.git` を置かない。
- CC 環境に `ANTHROPIC_API_KEY` を入れない。

## 6. 公開リポジトリの運用（本番・未実施）

- 入力はあなたが Grok に渡した依頼だけ。他人の Issue / PR コメントは読ませない。
- フォークからの PR は処理しない。Issue は無効。
- シークレットスキャンとプッシュ保護を有効化。

## 7. 既定値

| 項目 | 既定値 |
|---|---|
| 停止判定 | 工程 60 分で abort。1 回リトライ後 `factory-notify`（`FACTORY_STALL_TIMEOUT_SEC` で短縮テスト可） |
| 周回記録 | `round-N`（local labels / 将来 PR labels） |
| agmsg | プラグインが start/end を local ログへ。team 設定時のみ send.sh |
| 通知 | `local/notify/` + 任意 agmsg |
| 題材言語 | Python **3.12**（uv で box に導入。3.13 はフォールバック） |
| バックエンド | `FACTORY_BACKEND=local` |
| 使用量記録 | `local/usage/<date>/*.jsonl`（工程ごとの wall time / tokens、agmsg backlog）。`factory-usage summary` で集計 |
| IMPL 並列 OpenCode | strategy 欠落時 **既定 2**（最大 4）。本番は CC の `spec/IMPL_STRATEGY.md`；`FACTORY_OC_PARALLEL` は試験/緊急上書き。勝者は acceptance 採点 |
| OpenCode reasoning | モデル ID は `opencode-go/deepseek-v4.1-flash`。`reasoningEffort=max` を `factory-oc-provision` が共有 HOME に書き、新規スロットは `seed_oc_home` がコピー |

## 8. 未決定 → 決定済み / 残

- **factory プラグインの置き場所:** **決定** — 題材と分離。
- **隔離の方式:** **決定** — docker 不可のため factory-oc + bwrap。
- **権限の許可リスト:** **決定** — CC は PreToolUse コマンドフック（`lib/cc/hook.mjs`、全ツール、例外時 deny）+ FS chmod + 工程後 verify。OpenCode は `permission: allow` + 隔離。
- **残（ユーザー）:** GitHub リポ作成、PAT、ブランチ保護、本番の人間仕様承認。

## 9. 受け入れたリスク

- Grok への権限集中（全体管理・gate/grok・マージ）。
- サブスク CC トークンをクラウドに置く。
- 公開リポでは成果物・ログが公開される前提。
- Claude Code CLI の stream-json / フック入出力の形に依存（ピン `config/claude-code.json`、更新は承認制で pong 検証つき）。
- agmsg は送信者検証なし → 判定に使わない。

## 10. 検証結果

| 段階 | 結果（2026-11-04） |
|---|---|
| P0 | box 調査済み（ツール・永続・隔離手段あり） |
| P1 | DSH / factory プラグイン / OpenCode / agmsg 導入済み（DSH は 2026-11-14 撤去、§11） |
| P2 | CC が OAuth で応答 |
| P3 | OpenCode 隔離 Test A/B PASS（Go キー + Global）。子 env は `OPENCODE_API_KEY` のみ |
| P4 | **ローカル模擬**（status/labels/PR/merge + github バックエンドはモック HTTP 単体テスト）。実 GH 保護は未 |
| P5 | ローカル 4 シナリオ PASS（happy / tamper / 3 周 / stall） |

### P5 シナリオ結果（ローカル）

1. **正常系:** `factory-run-local` → main へマージ（bare origin）。
2. **改ざん:** 受入れ変更 → guard FAIL → merge 不可。
3. **3 周:** 不可能受入れ → 3 周後 `factory-notify max-rounds`。
4. **stall:** 短タイムアウト → 1 リトライ → notify。

## 11. 標準 CLI を直接起動する（2026-11-14、DSH 撤去）

`bin/factory-step` → `lib/factory_step.py` が 1 工程 1 プロセスで CLI を起動する。モデルを持つ親エージェントは無い。

- CC: `claude -p "<task>" --output-format stream-json --verbose --model claude-opus-5-5 --effort xhigh --permission-mode acceptEdits --permission-prompts none --setting-sources user --strict-mcp-config --settings <hooks>`。`CLAUDE_CODE_EFFORT_LEVEL=xhigh` も固定（env は `--effort` より優先）。ピンは `config/claude-code.json`。
- 認証は `CLAUDE_CODE_OAUTH_TOKEN` だけ。`ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN`、OpenCode / DeepSeek の鍵は子 env から外す。`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` は使わない（2.1.319 では permission mode を `default` に落とし Bash を sandbox に入れるため、`-p` で編集できなくなる）。`--bare` は OAuth を読まないので使わない。
- 許可リスト: `--settings` で PreToolUse（matcher `*`）/ Stop / StopFailure を `node lib/cc/hook.mjs` に結ぶ。PreToolUse は `lib/cc/allowlist.js` で allow/deny を返し、`FACTORY_CC_STEP` が無い・入力が壊れている・例外のときは deny。フック自体が落ちたときも `|| exit 2` でツール呼び出しを止める（CC はフックの異常終了を非ブロッキング扱いにするため）。
- 使用量と上限: stream-json の `system/init`・`system/api_retry`・`result` を usage sidecar（`claude-cli.*`）に書き、`factory-provider-state` が上限を判定して exit 75 で park する。
- timeout: 工程予算を過ぎたら SIGINT → SIGTERM → SIGKILL（プロセスグループ）、exit 124。
- OpenCode: `sudo -n bin/opencode-acp-isolated run <task>` → bwrap → `opencode run --standalone --format json --auto --archived`。隔離と sudoers は従来どおり（launcher 名も据え置き）。

## 12. 実装からの主な逸脱・補足

1. **canUseTool と Write:** 旧 Agent SDK 経路は Write でコールバックを呼ばなかった。標準 CLI の PreToolUse フックは Write/Edit にも効くが、実効制御の正は引き続き **FS 書込許可 + verify**（`DECISIONS.md`）。
2. **OpenCode 無料枠誤診:** 実際は Go 有料。`OPENCODE_GO_KEY` と `opencode-go/deepseek-v4.1-flash`、Privacy Global。
3. **Python:** 設計 3.12、box 既定 3.13 → uv で 3.12 を入れ `factory-ci` が優先。
4. **GitHub:** `FACTORY_BACKEND=github` 実装済みだが、トークン未設定のため運用は local。

## 参考

- [Claude Code headless](https://code.claude.com/docs/en/headless) / [hooks](https://code.claude.com/docs/en/hooks)
- [fujibee/agmsg](https://github.com/fujibee/agmsg)
- 付録の環境調査プロンプトは初版設計を参照（実施済み）。
- `docs/layout.md` / `docs/gate-grok.md` / `DECISIONS.md`
