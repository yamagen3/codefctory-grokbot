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
- [ ] OpenCode tokens は stats 差分のため、OC 工程が同時に走ると混ざる（notes に記録）。
- [ ] agmsg unread プローブは内部 API（`lib/storage.sh` の `storage_list_unread`）依存。存在しない team でも 0 を返すため、team/agent 名の誤りを検出できない。
- [ ] `factory-local-dry-run` は run summary を出さない（factory-step 単位の記録のみ）。
- [x] OpenCode Go 残量 `factory-usage balance`（zen/go/v1/usage）。CC 残量は非公式 API 不使用のため対象外。
- [ ] OC Go の percent は粗い（実 tokens が動いても 0% のまま）。精度が必要なら tokens 側（stats 差分）を正とする。
- [x] CC を claude-opus-5-5 + xhigh にピン（SDK 0.3.318 / claude 2.1.318、実 pong で cc_effort=xhigh 確認）。
- [x] box 部分初期化からの OpenCode 隔離復旧（`factory-oc-provision`、doctor PASS / OC pong / leak 14/14）。
- [ ] `plugin/node_modules` の自動復旧（`npm ci`）を factory-setup に入れるか検討。
- [ ] `factory-step` は plugin import 失敗時も dsh が exit 0 を返し得る（出力なしで成功扱い）。
- [ ] DSH が SDK ピンを上げたら `config/headless.pnpm-workspace.yaml` の overrides を外す（DSH のピン ≥ override なら不要）。

## multi OpenCode / 隔離 follow-ups（2026-11-05）
- [x] `FACTORY_OC_PARALLEL` impl-level fan-out + acceptance winner + per-slot `FACTORY_OC_HOME`。
- [x] CC が SPEC で `spec/IMPL_STRATEGY.md`（`parallel: N`）を決め、IMPL は parallel-first（欠落時既定 2；env は上書き）。
- [x] OpenCode Go の max reasoning を `factory-oc-provision` の既定 opencode.json に固定（`settings.reasoningEffort=max`。再プロビジョンと新規スロット HOME が継承。既存スロットはスナップショットのまま）。
- [x] CC SPEC/gate が pstack 段階スキル本文を Agent SDK options で受け取る（`pstackQueryOverlay`）。poteto-mode 自動ルートは不採用。box 上の実セッション確認は `factory-setup` 後。
- [ ] 他の並列化候補（multi-candidate gate、multi-run など）— SPEC/IMPL 以外も parallel-first で検討。
- [ ] OpenCode egress 制限（`--unshare-net` + opencode.ai だけ通す proxy）。並列時のトークン混線（stats 差分）も悪化し得る。
- [ ] launcher を root 所有の libexec へ移し checksum 照合（sudoers が box 書込可能スクリプトを root 実行している問題）。
- [ ] `factory-cc` ユーザー + bwrap（CC の chmod allowlist 限界の本命）。
- [ ] DSH plugin 内 multi-activation（Candidate B）は見送り。上流が one-shot を超えたら再検討。
- [ ] 並列時の `FACTORY_IMPL_PARALLEL_TIMEOUT_SEC` を stall-retry とどう揃えるか。
