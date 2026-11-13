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

## Fable レビュー第 2 回（2026-11-13）由来
- [x] R2-T1: Grok 判定の孤立防止（wait タイムアウトは既定で park＝pending 化して exit 2、`grok-pending` 通知、sha 検証と短縮 sha 解決、rejected 後の success 再記録で merge、continue のエラー通知）。`FACTORY_GROK_ON_WAIT_TIMEOUT=fail` で旧動作。
- [x] R2-T2: gate/claude は step exit を見る（0 pass / 1 fail / 75 判定なし / 124 timeout）、FAIL 行が優先、allowlist を trap で復元、出力先 `FACTORY_GATE_CLAUDE_OUT`。
- [x] R2-T3: 失敗ラウンドの理由を次ラウンドの IMPL プロンプトへ（`bin/factory-feedback`、`local/runs/<id>/`、秘密らしき行は伏字）。run が 0/2/3/75 以外で終わると `run-aborted` 通知。gate 不通（75/124/137）は IMPL ラウンドを消費せず exit 75。
- [x] R2-T4: `factory-inbox list|count|check|ack`（Grok/人間が「工場が何を待っているか」を一目で見る。仕組みのみ）。
- [x] R2-T5: test_fresh_paths の境界、patch 抽出の cache/venv 除外、LocalBackend の sha 検証を全経路に、docs/layout.md の受入閾値。
- [ ] R2-F7: `pr_merge` が origin を fetch せずにローカル main へ merge（長い pending 後は push 失敗で止まる）。【要判断】移動した main への自動 merge は merge 結果の CI で足りるか、rebase + gate 再実行か。
- [ ] R2-F8: pending 中に同じ id を再実行すると work clone を消す（後の判定が continue-stale になる）。
- [ ] R2-F9: Grok 拒否（exit 4）後に次ラウンドを自動開始（state.json + `--resume`、feedback を再利用）。
- [ ] R2-F10 / F13: `factory-update` 結果の通知と run との flock 共有。
- [ ] R2-F11: 並列 IMPL のプロセスグループ kill・固定 /tmp ログ・敗者 workspace 削除、全スロット timeout 時の exit 124（要テスト）。
- [ ] R2-F12: キューと worker。
- [ ] V11: CC allowlist の決定ログを `local/logs`（0600）へ（現在は内容は安全化済みだが /tmp の world-readable）。
- [ ] 【要判断】inbox の締切ポリシー（沈黙＝続行にするか）。

## 改善ループ第 3 回（2026-11-13、単一プロバイダー依存）由来
- [x] R3-T1: CC の利用上限・過負荷を判定して park（`bin/factory-provider-state`、factory-step の事前チェックと事後判定、stall-retry はリセットまで待って再実行、`provider-limited` 通知）。usage sidecar が `is_error` / `api_error*` / `result_head` を記録する。
- [x] R3-T2: `factory-update` は CC 上限中なら何も適用せず `deferred-provider`（exit 40）、検証中の上限・過負荷は退行扱いにせず `deferred-provider` と `update-deferred` 通知。
- [ ] OpenCode 側（opencode-go）の 429・上限の文言サンプルを採り、同じ park を OC step にも入れる。
- [ ] 実の DSH 経路で sidecar の新フィールドが記録されることを、次に CC が上限に達したときに確認する（今回はスタブでのテストのみ）。
- [ ] 【要判断・要認証情報】CC 不通時の代替 SPEC/gate。案は、OpenCode（flash, max）を gate の 2 次判定に使う、または `docs/extensibility.md` のアダプター経由で別プロバイダーを使う。モデル設定の変更と新しい鍵が要る。
- [ ] 【要判断】上限の枠を工場の実行とレビュー・保守で分ける（例: レビューは別アカウント・別トークン、または工場の実行中はレビューを止める）。
## 改善ループ第 4 回（2026-11-13、Fable medium）由来
- [x] R4-T1: 実 sidecar 形式（`result_head`、複数 writer）での上限判定、結果レコードが無いときの stderr 判定、過負荷の短時間 park、通知は 1 回、`ingest` でレビュー側の上限も記録。
- [x] R4-T2: factory-update の事前待機（既定 5400 秒）、退行を隠さない判定、連続延期の通知。
- [x] R4-T3: run の `state.json` と `bin/factory-resume` で park された run を自動再開。
- [x] R4-T4: inbox に上限中プロバイダーと park 中 run を表示、attention で数える。
- [ ] `factory-resume` を定期的に（または上限明けに）呼ぶ仕組み（cron / routine）を決める。今は手動か外側のループから呼ぶ。
- [ ] Fable のレビュー実行（`fable-*.sh`）で、終わったあと `factory-provider-state ingest claude-code` を呼ぶようにする。
- [ ] 【要判断】`pr_merge` が `main` の更新を取り込まずにマージする件、および同じ id の再実行で保留中の作業クローンを消す件（R4-F10、第 2 回からの持ち越し）。
- [ ] 並列 IMPL のタイムアウト処理・`/tmp` ログ固定・負けた workspace の残留（R4-F11、持ち越し。launcher フラグは要判断）。
- [ ] パイプライン記述子とプロバイダー名の継ぎ目はまだ docs のみ（R4-F12、読み取り専用の記述子なら実装可）。
## 改善ループ第 5 回（2026-11-13、Fable medium、上限の最終回）由来
- [x] R5-T1: run lock、再開時の round/sha 保持、`work`/`max_rounds` の保存、上限中の gate park は通知しない、孤立 run の検出（exit 137 + `run-aborted` 1 回）。
- [x] R5-T2: `bin/factory-tick`（resume → inbox check、`tick.json`、exit 10/75/0）。
- [ ] 【要判断】`factory-tick` のタイマーを入れるか、何で（cron / systemd timer / Grok のループ）、間隔は（例: 10 分）。
- [ ] 【要判断】text fallback の厳格化（R5-F6）: stdout を走査対象から外すか、「resets」句を必須にするか。まずスタブで再現する。text で見つけた 529 が 1 時間 park になる件も合わせて。
- [ ] Fable のレビュー実行スクリプト（追跡外）で `factory-provider-state ingest claude-code` を呼ぶ（R5-F7）。
- [ ] 第 5 回で上限に達したため Fable の再レビューはしていない。次にループを回すときは第 5 回の変更（PR #10）の検証から始める。
## 改善ループ第 6 回（2026-11-14、Fable medium）由来
- [x] R6-T1: 自動再開の回数上限（既定 5）、impl 段階の再開、tick の再開ログ、孤立通知の失敗で止まらない。
- [x] R6-T2: Grok の差し戻しを次ラウンドとして自動で積み直す（`grok-rejected-requeued`）。
- [x] R6-T3: `profiles/default.json` と `bin/factory-profile`（記録とずれ検出のみ）。
- [x] R6-T4: `bench/` の骨組みと `bin/factory-bench`（validate / オフライン採点）。
- [ ] profile 第 2 段階: スクリプトが既定値を profile から読む。`factory-doctor` に `factory-profile check` を入れる（第 7 回候補）。
- [ ] 【要判断】2 つ目の profile と切り替え。新しい頭脳・製造モデル、CC 不通時の代替頭脳は、モデル設定の変更と新しい認証情報が要る。
- [ ] 【要判断】ベンチを有料モデルで回すか、誰が・どの頻度で・予算はいくらか。隠しチェックを製造側から見えない場所に置く方法。
- [ ] run の state と usage に profile id を記録する（第 7 回候補）。
## 改善ループ第 7 回（2026-11-14、Fable medium）由来
- [x] R7-T1: 受付キュー `bin/factory-queue` と tick からの 1 件ずつの起動。
- [x] R7-T2: profile を run 開始時に照合・記録、doctor でも照合、check の厳格化。
- [x] R7-T3: `factory-bench collect`（終わった run → ベンチ結果）。
- [x] R7-T4: 早く死んだ resume も試行として数える。
- [ ] 【要判断】キューの方針: Grok が人なしで積んでよいか、キューの最大長、同じ target で同時に複数の run を許すか。
- [ ] 【要判断】ベンチの隠しチェックの置き場所（OC の workspace から見えない場所）と、マージ後のツリーに対して誰が走らせるか。
- [ ] 【要判断】`factory-tick` のタイマー。キューが入ったので、これ 1 つで人なしに回り始める。