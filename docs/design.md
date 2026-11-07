# コードファクトリー設計 v0（実装反映版）

状態: P0〜P5 を **ローカル模擬**まで完了（2026-11-04）。GitHub 実リポジトリへの push / 保護設定は未着手（ユーザー作業）。

## 0. 前提: 実行環境を最新に保つ / OpenCode は parallel-first

factory は実行環境を最新に保つ。DSH、Agent SDK / Claude Code、OpenCode と関連ツールは、必要なモデルや機能（例: CC の `claude-opus-5-5` + effort `xhigh`）が常に使えるよう更新する。更新は必ず `factory-update` のスナップショット → 検証 → 自動ロールバック経路を通す。日次バッチは従来どおりセキュリティ修正と patch/minor を自動適用し、本体（DSH / SDK / major）の更新は「重大脆弱性」または「必要なモデル・機能のために最新化が要る」ときに承認つきで行う（`factory-update apply --approve`）。

**OpenCode IMPL は parallel-first。** 並列度 N は人間が env で毎回いじるものではなく、SPEC 工程の Claude Code が `spec/IMPL_STRATEGY.md`（`parallel: N`）で決める。並列が効くところは前提として押し、N=1 は小さな逐次変更など本当に無駄なときだけ。

## 1. 構成

```text
あなた
  | 依頼 / 本番の仕様承認 / 停止時の判断
  v
Grok Bot (クラウド box)   全体管理、受入れ確認、gate/grok、マージ
  | 工程ごとに DSH を起動
  v
DSH + factory プラグイン  指示役(モデルなし)、子プロセス管理、agmsg/ログ
  ├ Agent SDK → CC        仕様、受入れテスト、gate/claude
  └ ACP → OpenCode (隔離)  実装（OpenCode Go / DeepSeek）

agmsg / local/logs        進捗の参考情報（判定根拠にしない）
題材リポ（local bare origin → 将来 GitHub 公開）  成果物と判定の正本
factory リポ（/workspace/factory）  オーケストレータ本体（OpenCode から不可視）
```

## 2. 決定事項

| # | 論点 | 決定 |
|---|---|---|
| Q1, Q8 | 実行場所 | Grok Bot のクラウド box。この PC の DSH 設定は流用しない |
| Q2, Q14 | 最初の対象 | 新規 CSV→Markdown 表 CLI（stdlib のみ、Python 3.12） |
| Q3 | 第二ゲート | Grok（`factory-gate-grok` + レビュー束）。通れば自動マージ |
| Q4 | 差し戻し | 全ゲート合格のときだけマージ。実装は最大 3 周。超えたら `factory-notify` |
| Q5 | 権限 | OpenCode は factory-oc + bwrap。渡すのは `OPENCODE_API_KEY`（Go）のみ |
| Q6 | 進捗管理 | agmsg（任意）+ 常時 `local/logs/agmsg-progress.log`。判定根拠にしない |
| Q7 | 起動の流れ | Grok が管理し、DSH が CC / OpenCode を抱える。DSH モデルは使わない（§11） |
| Q9 | Git リモート | 本番は GitHub Free 公開リポ。**現在は local bare origin**（`FACTORY_BACKEND=local`） |
| Q10 | 仕様の承認 | 本番は人間。**ローカルは自動承認**（`spec/<id>` タグ、`DECISIONS.md`） |
| Q11 | CC の認証 | `CLAUDE_CODE_OAUTH_TOKEN` |
| Q12 | 実行単位 | 工程ごとに DSH を 1 回起動 |
| Q13 | 第一ゲート | CC が受入れを先に書く。実行は ci。照合は `gate/claude` |
| — | factory の置き場所 | **題材と分離**（`docs/layout.md`）。OpenCode の bwrap は factory をマウントしない |
| — | OpenCode モデル | 有料 OpenCode Go。`opencode-go/deepseek-v4.1-flash`。Privacy Regions=**Global** 必須 |
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
| DSH 親 | 子へ渡す値だけ（スクラブ後） | 管理権限トークンを常駐させない |
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

## 8. 未決定 → 決定済み / 残

- **factory プラグインの置き場所:** **決定** — 題材と分離。
- **隔離の方式:** **決定** — docker 不可のため factory-oc + bwrap。
- **権限の許可リスト:** **決定** — CC は FS chmod + 工程後 verify。Agent SDK は Write で `canUseTool` を呼ばないため、フック単体では不足（防御層として残置）。OpenCode は ACP `permission: allow` + 隔離。
- **残（ユーザー）:** GitHub リポ作成、PAT、ブランチ保護、本番の人間仕様承認。

## 9. 受け入れたリスク

- Grok への権限集中（全体管理・gate/grok・マージ）。
- サブスク CC トークンをクラウドに置く。
- 公開リポでは成果物・ログが公開される前提。
- DSH rc 版内部 API 依存（CC パッチは DSH の 1 行一致に依存。崩れたら setup が失敗し factory-update がロールバック）。
- agmsg は送信者検証なし → 判定に使わない。
- プロファイル再インストールで CC allowlist パッチが外れる → `factory-setup` で再適用。

## 10. 検証結果

| 段階 | 結果（2026-11-04） |
|---|---|
| P0 | box 調査済み（ツール・永続・隔離手段あり） |
| P1 | DSH / factory プラグイン / OpenCode / agmsg 導入済み |
| P2 | CC が OAuth で応答 |
| P3 | OpenCode 隔離 Test A/B PASS（Go キー + Global）。子 env は `OPENCODE_API_KEY` のみ |
| P4 | **ローカル模擬**（status/labels/PR/merge + github バックエンドはモック HTTP 単体テスト）。実 GH 保護は未 |
| P5 | ローカル 4 シナリオ PASS（happy / tamper / 3 周 / stall） |

### P5 シナリオ結果（ローカル）

1. **正常系:** `factory-run-local` → main へマージ（bare origin）。
2. **改ざん:** 受入れ変更 → guard FAIL → merge 不可。
3. **3 周:** 不可能受入れ → 3 周後 `factory-notify max-rounds`。
4. **stall:** 短タイムアウト → 1 リトライ → notify。

## 11. モデルなしで DSH に CC / OpenCode を抱えさせる

`factory.patch.yml` で headless-runner を無効化し、factory-orchestrator が `startActivation` する（設計当初どおり）。

- CC: `permissionMode: acceptEdits` + `FACTORY_CC_STEP` + FS allowlist。
- OpenCode: `sudo` → `opencode-acp-isolated` → bwrap → `opencode acp`。
- ダミー親モデル（`deepseek-official/deepseek-flash`）は呼ばれない。

## 12. 実装からの主な逸脱・補足

1. **canUseTool と Write:** SDK が Write でコールバックを呼ばないため、実効制御は **FS 書込許可 + verify**（`DECISIONS.md`）。
2. **OpenCode 無料枠誤診:** 実際は Go 有料。`OPENCODE_GO_KEY` と `opencode-go/deepseek-v4.1-flash`、Privacy Global。
3. **Python:** 設計 3.12、box 既定 3.13 → uv で 3.12 を入れ `factory-ci` が優先。
4. **GitHub:** `FACTORY_BACKEND=github` 実装済みだが、トークン未設定のため運用は local。

## 参考

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
- [fujibee/agmsg](https://github.com/fujibee/agmsg)
- 付録の環境調査プロンプトは初版設計を参照（実施済み）。
- `docs/layout.md` / `docs/gate-grok.md` / `DECISIONS.md`
