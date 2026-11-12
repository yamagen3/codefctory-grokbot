# Factory TODO / ブロッカー一覧

## ユーザー対応が必要なもの（P4 / GitHub）
- 公開 GitHub リポジトリ（csv2md 用）: https://github.com/yamagen3/codefctory-grokbot （ユーザー作成済み。push はトークン受領＋ユーザーの合図後）。
- Fine-grained PAT（Grok 用）: contents / pull requests / statuses（Administration なし）。
- Fine-grained PAT（CC 用）: statuses のみ。
- ブランチ保護（main）: 必須チェック `guard` / `ci` / `gate/claude` / `gate/grok`、管理者も迂回不可。
- Secret scanning + push protection。
- Issues 無効化、フォーク由来 PR は処理しない運用の確認。
- 上記トークンを box シークレットへ登録（値はチャットに貼らない）。
- （任意）不要な `DEEPSEEK_API_KEY` を削除。
- 本番の仕様承認ポリシー（ローカルは自動承認済み）。

## ローカル完了（参照）
- P0–P5 ローカル、factory git、BACKEND local|github（モック試験済）、gate/grok 束+record、厳格 patch、factory-setup/doctor、設計更新。


## エージェント進行中 / 今回追加
- [x] factory-timeline v1.2 run `timeline-v1.2-20261104-143021` merged (main 経由で v1.3 `7dc5fde` まで完了)。
- [x] factory-timeline v1.1 run `timeline-v1.1-20261104-132827` sha `a916dba…` merged to main `344843b`.
- pstack: インストール済み（doctor チェックあり）。プロファイル再インストール後は `factory-setup` / `factory-pstack-install`。
- [x] factory-timeline v1〜v1.3 工場通し完了（main=`7dc5fde`）。
- （任意）OpenCode が skills を読むパスの版差（`.agents/skills` vs `.config/opencode/skills`）を upstream 追従時に再確認。

## エージェント側の薄い残り（任意）
- github バックエンドの結合試験（実トークン入手後）。
- `factory-run-local` への `factory-pr create` 自動配線の整理。
- patch を git binary 差分形式に寄せる（現在 diff -ruN）。

## gate/grok レビューで見つけた factory 側の改善（2026-11-04）
- [x] レビュー束に merge-base(origin/main,HEAD)…HEAD の `diff.full.*` を追加（`factory-gate-grok` + docs）。
- 同一 run 内の仕様再凍結（fixture 修正）は今回エージェント判断で実施。本番では人間承認ポリシーに従うこと。
- [x] `factory-merge` 他 bin の repo 引数を `resolve_repo`（realpath）で正規化。smoke: `local/tests/test_resolve_repo.sh`。

## factory-timeline（完了）
- [x] v1.2: `#untimed` / TZ トグル / `#event-detail`（merged）。

## factory-timeline（v1.3 完了）
- [x] JST 既定（固定 +09:00）+ JST/UTC トグル、詳細パネル含む（main=`7dc5fde`）。

- [ ] factory-timeline v1.4 候補: Untimed 欄のテキストが JST/UTC トグルに追従しない（epoch 時刻なので "ts=1970-01-01 09:00 JST" 表示自体を「時刻不明」に置き換える案）。summary の First/Last Event 列は v1.3 で spec 側が追加したもの。

## animal-trendcast（AppDev 担当）
- [x] v1 / v1.1 / v2 まで local origin main に merge 済み（最新 `182a441`）。gate/grok は AppDev が記録。

## factory 改善（2026-11-05 / AppDev 報告）
- [x] `FACTORY_STALL_TIMEOUT_SEC` 既定 3600（60分）。
- [x] `FACTORY_TARGET_NAME` 必須化（csv2md 既定撤去）。
- [ ] 進捗ベースの stall 判定（ログ/ハートビートで延長）。当面は env で上書き可。

## セキュリティ更新バッチ（factory-update, 2026-11-05）
- [x] `bin/factory-update check|apply|daily`、ロック、ロールバック試験（`local/tests/test_factory_update.sh`）、`factory-oc-leak-check`、repo-template `dependabot.yml`。
- [ ] スケジューラ登録（Grok routine で毎日 JST 早朝。コマンドは docs/layout.md）。
- [x] DSH 0.2.2-rc.1 適用済み（承認）。[ ] 残: CC SDK 0.3.318 / zod GHSA-mrhx-c7xc-m3w5 は次の DSH リリース待ち、pstack 再ピン判断、global の undici/fflate/@modelcontextprotocol/client 脆弱性（所有パッケージの上流リリース待ち）。
- [ ] repo-template の actions を commit SHA ピンへ（checkout@v4 ×2, setup-python@v5）。
- [ ] apt ミラー 500 継続時の扱い（現状 warning のみ、セキュリティ更新は取得不可）。
- [x] (spec を凍結前にコミットするよう修正) `factory-local-dry-run` の揺れ: CC が spec 工程で `tests/acceptance/test_placeholder.py` を消すと impl が保護パス扱いで spec を落とし gate FAIL になる（spec 凍結前に spec をコミットすべき）。

## 使用量記録（factory-usage, 2026-11-05）
- [x] JSONL 記録・`factory-usage show|summary|agmsg`・run 終了サマリ・テスト。
- [x] CC tokens: subagent パッチの usage sidecar で記録（modelUsage）。[ ] DSH 上流に usage 素通しを要望（パッチ依存を外すため）。
- [x] 並列 IMPL の OpenCode tokens はスロットの `FACTORY_OC_HOME` の stats 差分（共有 home を同時に読むと 0 または混線になる）。`impl-sN` は `step=impl` + `oc_slot`。`oc_model` / `oc_reasoning_effort` はスロットの opencode.json。
- [ ] 共有 `/home/factory-oc` を同時に使う工程（`FACTORY_OC_HOME` なし）の stats 差分は今も混ざる。egress 制限とあわせて残る。
- [ ] agmsg unread プローブは内部 API（`lib/storage.sh` の `storage_list_unread`）依存。存在しない team でも 0 を返すため、team/agent 名の誤りを検出できない。
- [ ] `factory-local-dry-run` は run summary を出さない（factory-step 単位の記録のみ）。
- [x] OpenCode Go 残量 `factory-usage balance`（zen/go/v1/usage）。CC 残量は非公式 API 不使用のため対象外。
- [ ] OC Go の percent は粗い（実 tokens が動いても 0% のまま）。精度が必要なら tokens 側（stats 差分）を正とする。
- [x] CC を claude-opus-5-5 + xhigh にピン（SDK 0.3.318 / claude 2.1.318、実 pong で cc_effort=xhigh 確認）。
- [x] box 部分初期化からの OpenCode 隔離復旧（`factory-oc-provision`、doctor PASS / OC pong / leak 14/14）。
- [x] `plugin/node_modules` は `factory-setup` が `npm ci --omit=dev` で入れる。doctor は `@deepseek-ai/schemastery` 欠落を FAIL。
- [x] `factory-step` は plugin が `factory: step end` を出さず stdout も空なら exit 1（dsh が import 失敗を 0 で返しても成功扱いにしない）。
- [ ] DSH が SDK ピンを上げたら `config/headless.pnpm-workspace.yaml` の overrides を外す（DSH のピン ≥ override なら不要）。

## multi OpenCode / 隔離 follow-ups（2026-11-05）
- [x] `FACTORY_OC_PARALLEL` impl-level fan-out + acceptance winner + per-slot `FACTORY_OC_HOME`。
- [x] CC が SPEC で `spec/IMPL_STRATEGY.md`（`parallel: N`）を決め、IMPL は parallel-first（欠落時既定 2；env は上書き）。
- [x] OpenCode Go の max reasoning を `factory-oc-provision` の既定 opencode.json に固定（`settings.reasoningEffort=max`。再プロビジョンと新規スロット HOME が継承。既存スロットはスナップショットのまま）。
- [x] CC SPEC/gate が pstack 段階スキル本文を Agent SDK options で受け取る（`pstackQueryOverlay`）。poteto-mode 自動ルートは不採用。box 上の実セッション確認は `factory-setup` 後。
- [x] doctor が OpenCode `reasoningEffort=max` の欠落を FAIL する（ソース既定と live `opencode.json`）。
- [x] 承認済み SDK 写しを 0.3.319 / Claude Code 2.1.319 に合わせた（インストールは box 側）。
- [x] SPEC の CC プロンプトは Claude Code `/goal <条件>`（DSH `/goal` は親だけなので不使用）。
- [ ] CC `/goal` が Agent SDK `persistSession: false` の query で複数 turn するか未検証。box では素の `/goal` が CC の usage 応答（0 model turn）になることだけ確認。
- [ ] CC が `/goal` 条件を先頭行だけとるか、プロンプト全体とるかは未再確認。ソースは条件を先頭行（4,000 文字以内）に固定し、brief 全文はその後に残す。
- [ ] OpenCode に `/goal` 相当は無い。IMPL は通常プロンプトのまま。同等の完了条件を OC に渡すかは未決。
- [x] `factory_oc_write_config` が max 無しの opencode.json を max 付きへ置き換え、2 回目は unchanged。
- [ ] 他の並列化候補（multi-candidate gate、multi-run など）— SPEC/IMPL 以外も parallel-first で検討。
- [ ] OpenCode egress 制限（`--unshare-net` + opencode.ai だけ通す proxy）。並列時のトークン混線（stats 差分）も悪化し得る。
- [ ] launcher を root 所有の libexec へ移し checksum 照合（sudoers が box 書込可能スクリプトを root 実行している問題）。
- [ ] `factory-cc` ユーザー + bwrap（CC の chmod allowlist 限界の本命）。
- [ ] DSH plugin 内 multi-activation（Candidate B）は見送り。上流が one-shot を超えたら再検討。
- [ ] 並列時の `FACTORY_IMPL_PARALLEL_TIMEOUT_SEC` を stall-retry とどう揃えるか。

## Fable レビュー第 1 回（2026-11-13、claude-fable-5-2）由来
- [x] T1: plugin の step timeout を stall 予算に連動（`plugin/step-timeout.js`、timeout は exit 124 で stall-retry に乗る）。
- [x] T2: `LocalBackend.status_set` の shell 注入を除去（`subprocess` 配列、sha 検証、flock + atomic write）。`pr_merge` は push 失敗で例外。
- [x] T3: `factory-gate-grok record` → `factory-continue` で pending 判定を自動続行（success は merge、failure は `grok-rejected` 通知）。`FACTORY_GROK_AUTO_CONTINUE=0` で停止。
- [x] F14 一部: patch 抽出がディレクトリ symlink を拒否し `diff --no-dereference`。CC allowlist は未知 step を deny、決定ログは入力を書かない。
- [x] 拡張性の設計提案 `docs/extensibility.md`（提案のみ。プロバイダー/モデル切替なし）。
- [ ] F1 残り: run-state（`local/runs/<id>/state.json`）と `factory-run-local --resume`、failure 時の次ラウンド自動再開。
- [ ] F2: 失敗理由を次ラウンドへ渡す（`feedback-r<N>.md` → `.factory-oc-feedback.md`）。
- [ ] F3: 終了コード契約（75 = 一時失敗 / quota で park、ラウンドを消費しない）。429 文言のサンプル採取が必要。
- [ ] 【要判断】F5: OpenCode が書いたコードの受入/CI 実行を sandbox 化（factory-oc + bwrap `--unshare-net`）。sudoers/launcher 変更のため承認が必要。自動 merge を信用する前提条件。
- [ ] F6: ファイルキュー `local/queue/` と worker、`/tmp` 固定パスの run 別化と target ロック。
- [ ] F7: `factory-inbox`（Grok/人間共通の受信箱、deadline 付き既定動作）。【要判断】締切で黙認＝続行とするポリシー。
- [ ] 【要判断】F8: Grok の held-out 受入テストの置き場所・作成者、`factory-run-local` の既定 stub pass を fail-closed にするか。
- [ ] F10: gate/claude の判定パース（最初の判定行が決める、step exit 0 必須、trap で allowlist 復元）。
- [ ] F12: 並列 IMPL のプロセスグループ kill、早期打ち切り、敗者 workspace 削除。【要判断】launcher の `--die-with-parent`。
- [ ] F13: `factory-update` の結果を通知、run と update の flock 共有、docs の acceptance ≥18 と既定 10 の不一致。
- [ ] 【要判断】max rounds 後の自動 re-spec を新 run id で 1 回許すか。
- [ ] 【要認証情報】GitHub backend の PAT 2 本とブランチ保護（既存項目）。
