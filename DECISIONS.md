# 決定ログ（ローカル実装）

- 2026-11-04: factory は題材リポと分離（`/workspace/factory`）。OpenCode の bwrap が factory をマウントしないためプラグイン改変を防ぐ。
- 2026-11-04: ローカルでは GitHub の代わりに bare origin + `factory-status`（JSON/git notes）+ `factory-labels` で statuses/labels を模擬。後で同一インターフェースを GH API に差替。
- 2026-11-04: 仕様承認はローカル実行では自動承認（`spec/<id>` タグ打刻）。本番の人間承認は P4 以降。
- 2026-11-04: CC の Write は Agent SDK が `canUseTool` を呼ばず `acceptEdits`/`auto` で通すため、**実効制御は FS 書込許可（chmod）+ 工程後のパス検証**とする。`canUseTool` フックは SDK が呼ぶ場合の防御層として残す。
- 2026-11-04: gate/grok は `FACTORY_GROK_STUB=pass|fail` で自動テスト、未設定時は hook ファイル待ち。
- 2026-11-04: 題材 CI は Python 3.12（uv で box に導入）。3.13 はフォールバック。
- 2026-11-04: agmsg は常に `local/logs/agmsg-progress.log` に開始/終了を書き、`FACTORY_AGMSG_TEAM` があるときだけ send.sh。
- 2026-11-04: P5 改ざん/3周/stall はモデル消費を抑えるため可能な範囲で stub/短タイムアウトを使い、happy path のみ実 CC+OC を使う。
- 2026-11-04: `factory-merge` は常に `user.email=factory@localhost` を付けてコミット（box に global git identity が無い）。
- 2026-11-04: patch extract の一時ディレクトリは `/tmp/factory-seed-*` に固定し、`tmp/` を成果物コミットから除外。
- 2026-11-04: `FACTORY_BACKEND=local|github`。github は Statuses/labels/PR/merge API。単体はモック HTTP。既定 local。
- 2026-11-04: gate/grok はレビュー束 + `record`。自動試験は stub。ガイドは `docs/gate-grok.md`。
- 2026-11-04: patch extract は保護パスを diff 前に削除し、binary/symlink を拒否。
- 2026-11-04: `factory-setup` で CC パッチ再適用、`factory-doctor` で健全性確認。
- 2026-11-04: pstack は `michael-denyer/pstack-claude` をピン `79b36d9b53a53c78e5ec26bf6ce7dade76686c87` で導入。`bin/factory-pstack-install`（`factory-setup` から呼ぶ）が再現インストール。CC は `~/.claude/skills/`、OpenCode は `/home/factory-oc/.agents/skills/`（bwrap 内 HOME。factory はマウントしない）。
- 2026-11-04: pstack はサブセット 44 スキル（原則群 + architect/tdd/blast-radius/interrogate/poteto-mode 等）。arena/swarm/reflect 等の無制御マルチモデル起動系、GH babysit/CI 系、ketchup-video、setup-pstack、create/maintain-*-skill、thermos 系は除外（`config/pstack-skills.manifest`）。
- 2026-11-04: `local/grok-hooks/` はランタイム状態のため gitignore（束・pending・result は再生成可能）。
- 2026-11-04: 第二題材は `factory-timeline`（工場ログ集約 CLI + オフライン単一 HTML ダッシュボード）。Python 3.12・stdlib のみ。スキャフォールドは `targets/factory-timeline-scaffold/`。
- 2026-11-04: `factory-spec-step` を題材非依存化（BRIEF / 既存 PRODUCT.md / pyproject name）。csv2md ハードコードを撤去。
- 2026-11-04: `factory-run-local` は `FACTORY_GROK_MODE=pending` 時に exit 2 で停止（周回継続しない）。`FACTORY_GROK_STUB` は MODE 未設定時のみ既定 pass。
- 2026-11-04: `factory-patch-extract` の binary scan は `__pycache__`/`*.pyc` 等を無視（OC が workspace 内でテスト実行するため）。`factory-impl-step` でも extract 前に pycache を削除。
- 2026-11-04: `factory-patch-extract apply` は `patch --batch --forward` で非対話（誤った対話プロンプトでツリーが壊れるのを防ぐ）。`.factory-round` は diff から除外。
- 2026-11-04: factory-timeline v1.1 — HTML `#timeline-data` は JSON を script-safe に埋め込む（`<`/`>`/`&`/U+2028/U+2029 を `\uXXXX`）。`JSON.parse(textContent)` が events と完全一致することを受入れで固定。
- 2026-11-04: grok result の ts 解決順は `recorded_at` → 同 sha の `pending.created_at` → 同 sha bundle META `generated`。どれも無ければ events には epoch で出すが、ダッシュボード時間軸は epoch/未解決を除外し `#untimed` リストへ（実データの 1970 引き延ばしを防ぐ）。
- 2026-11-04: v1.1 で OPEN_QUESTIONS を閉じる: (1) `NOTIFY.log` はマッチする `.txt` が無い行だけ追加、(2) 同一 run id の `round-N` を他ソースのイベントへ横断付与。
- 2026-11-04: v1.1 は既存 bare origin（main=5c62bd9）を `factory-local-origin init` で壊さない。新規 work clone + 個別ステップで回す（init はスキャフォールド再投入のため）。
- 2026-11-04: v1.1 SPEC 微修正 — ts_fallback の pending `created_at` を 2099 から軸内（2026-04-02T12:00Z）へ。PRODUCT の「epoch のみ軸除外」と受入れ期待の矛盾を解消（実装の undocumented stale-pending 除外は撤去）。
- 2026-11-04: `factory-gate-claude` は verify 前に `uv.lock` / `__pycache__` を除去（gate 中の CC がテスト実行で落とすエフェメラルを製品書込と誤認しない）。
- 2026-11-04: `factory-patch-extract make` は `.factory-round` を diff ツリーから削除（対話パッチ失敗の再発防止）。
- 2026-11-04: bin の repo 引数は `resolve_repo`（realpath）で絶対パス化。`factory-merge` の相対パス失敗を防ぐ。共通ヘルパは `factory-common.sh`。
- 2026-11-04: gate/grok 束に `diff.full.patch` / `diff.full.stat.txt` / `diff.full.meta.txt`（merge-base(origin/main,HEAD)…HEAD）を追加。`spec/<id>`…HEAD の diff も維持。docs/gate-grok.md と bundle README を更新。
- 2026-11-04: factory-timeline v1.2 — #untimed に可視テキスト+見出し、ローカル TZ 表示（既定）+UTC トグル（埋め込みデータは UTC のまま）、#event-detail パネルは textContent のみ。オフライン/script-safe 維持。
- 2026-11-04: `factory-run-local` は既存の bare origin を再初期化しない（以前は毎回 `init` で origin を消し scaffold を再投入していた）。強制は `FACTORY_ORIGIN_REINIT=1`。v1.3 から既存 origin に対し run-local をそのまま使う。
- 2026-11-04: factory-timeline v1.3 — 表示既定を JST（固定 +09:00、ブラウザ TZ 非依存）、`#tz-toggle` は JST/UTC。機械向け JSON は ISO-8601+offset のまま。工場のログ書込側は変更しない（ソースは +09:00/+00:00 混在のまま、パーサ側で offset 対応）。
- 2026-11-04: 第三題材 `animal-trendcast`（CLI `trendcast`）。オフライン episode.json → ナレーション原稿/キュー/SRT/ストーリーボード/silent program.mp4。Python 3.12・stdlib のみ + 外部バイナリは ffmpeg/ffprobe のみ。X API/ネットワーク無し。スキャフォールドは `targets/animal-trendcast-scaffold/`。box 環境: ffmpeg 7.1.5、日本語フォント (Noto Sans CJK JP 等) あり。Pillow は未導入（不要・禁止）。

- 2026-11-05: `FACTORY_STALL_TIMEOUT_SEC` 既定を 1800→3600（60分）。大きめ brief の SPEC が CC 稼働中に 30 分で切れる事例（AppDev / animal-trendcast v2）。進捗ベース停止は TODO。
- 2026-11-05: `factory-run-local` は `FACTORY_TARGET_NAME` 必須（既定 csv2md を撤去）。誤って別題材 origin を触らないため。brief も必須（`FACTORY_SKIP_CC_SPEC=1` 時は除外）。`factory-impl-step` 既定プロンプトの csv2md 文言も撤去。
- 2026-11-05: `FACTORY_STALL_TIMEOUT_SEC` が outer `factory-stall-retry` だけに効き、inner `factory.patch.yml` の `timeoutMs: 1800000` が別枠で CC/OC を 30 分 abort していた。abort の exit は 124 以外のため stall-retry も再試行しない。`timeoutMs` を `FACTORY_STALL_TIMEOUT_SEC * 1000`（未設定時 1800000）に連動させ、trendcast v2 SPEC の長尺 brief で 3600s が実効するようにした（animal-trendcast v2.1 着手前の blocker fix）。
- 2026-11-05: 上記 timeoutMs 連動は `factory.patch.yml` の `!!js` 三項が Cordis 上で object になり ValidationError となったため撤回。代わりに `plugin/index.js` が `FACTORY_STALL_TIMEOUT_SEC` を読んで timeoutMs を上書き（未設定時は patch の 1800000）。壊れた v2.1 試行 `trendcast-v2.1-20261105-100058` は SPEC/IMPL が空のまま進んだため中止し再起動。
- 2026-11-05: セキュリティ更新バッチ `bin/factory-update check|apply|daily` を追加。自動適用はセキュリティ修正と patch/minor のみ。major、DSH の rc/prerelease チャネル変更（rc→stable 含む）、CC SDK の変更は needs-approval。適用前に npm パッケージ dir / uv / factory-oc opencode / agmsg skill をスナップショットし、staging prefix に試験 install → 本番 install → `factory-setup`（CC パッチ + pstack 再適用）+ factory-oc opencode 再コピー（factory-setup は未対応のため factory-update 側で実施）→ verify（doctor / pong CC+OC / leak 14 項目 / CC FS allowlist / local dry-run 受入れ ≥18）。失敗時は自動ロールバック + doctor。apt ミラー 500 は warning 扱い。変更履歴は `local/updates/UPDATES-LOG.md`（gitignore、各 run の `result.json` へリンク）。初回 daily: agmsg 1.7.0→1.7.1（npm + skill）、uv 0.13.6→0.13.7 を適用し verify 全 PASS。
- 2026-11-05: user 承認により DSH を 0.2.1-rc.5→0.2.2-rc.1（global + headless プロファイルの dsh-subagent-* を同版に揃え、`config/headless.package.json` 同期）。`factory-update apply --approve <id|name@version>` を追加（その apply 限りで needs-approval を auto 扱い、daily の方針は不変）。DSH 適用時はプロファイル dir もスナップショット/ロールバック対象。Agent SDK 0.3.263 / zod 4.4.3 は rc.1 でも据え置きで、nested 脆弱性は解消せず（強制 override はしない）。詳細 `local/updates/UPDATES-LOG.md`。

## 2026-11-05 — security update policy (news for tool bodies)

Daily `factory-update` stays the base: inventory + auto-apply only small patch/security fixes for factory deps (agmsg, uv, …).
Tool-body upgrades (DSH, OpenCode, Agent SDK) are **not** driven by “a newer version exists”. They wait for major vulnerability news/advisories (RCE, secret leak, auth bypass, etc.), then verify and apply with approval. Reason: per-tool proactive bumps cost bandwidth for little gain.
- 2026-11-05: 使用量記録を JSONL（`local/usage/<date>/steps|agmsg|runs.jsonl`、追記のみ）で導入。`factory-step` が全 CC/OpenCode 起動の wall time を記録。tokens は推測しない: 結果 JSON に `usage` があれば採用（plugin は DSH が将来 `result.usage` を出せば素通し）、無ければ null + `source_missing`。現状 DSH の claude-code subagent 結果には usage が無く CC は null。OpenCode は factory-oc の `opencode stats --all --json` の前後差分（`token_source=opencode-stats-delta`、同時実行時は混ざる旨 notes）。Grok は pending→record の待ち時間のみ（tokens 不可視）。agmsg は send 回数/時間（plugin）と、`FACTORY_AGMSG_TEAM` 時に各工程前後で unread を読み取り専用プローブ（`storage_list_unread`、既読化しない）。agmsg/usage の失敗で工程は落とさない。
- 2026-11-05: CC tokens — 原因は DSH `dsh-subagent-claude-code` の `consumeClaudeQuery` が Agent SDK の result メッセージ（`usage`/`modelUsage`/`total_cost_usd`）を読んだうえで text だけ返し、さらに `persistSession:false` で transcript も残らないこと。対策: 既存の CC allowlist パッチ（`scripts/apply-cc-allowlist-patch.sh`、`factory-setup`/`factory-update` 後に再適用）に usage sidecar を追加し、`FACTORY_CC_USAGE_FILE` へ SDK result の usage を追記。`factory-step` が一時ファイルを渡し `factory-usage` が `modelUsage` 合計（サブエージェント含む）を記録（`token_source=cc-sdk-sidecar.modelUsage`、`cost_usd_estimate` は SDK 推定値で請求額ではない）。パッチ欠落時は null のまま（doctor が WARN）。
- 2026-11-05: 残量表示。Claude Code の残量は非公式 API（Anthropic OAuth usage 等）を使わない方針で対象外（工程ごとの tokens は SDK result の sidecar で記録済み）。OpenCode Go は OpenCode Go 自身がメーター表示に使う `GET https://opencode.ai/zen/go/v1/usage`（`Authorization: Bearer $OPENCODE_GO_KEY`、キーは表示しない）を `factory-usage balance` で読み、remaining=100-percent（rolling 5h / weekly / monthly、resetsAt は JST 表示）。percent が無ければ unknown（推測しない）。`factory-run-local` 終了時に `local/usage/<date>/balance.jsonl` へ best-effort スナップショット。
- 2026-11-05: user 要件「CC は claude-opus-5-5 + effort xhigh」。設定方法は `config/factory.patch.yml` の subagent-claude-code `model: claude-opus-5-5` + env `CLAUDE_CODE_EFFORT_LEVEL: xhigh`（doctor が未設定を WARN）。ただし現行 Agent SDK 0.3.263 同梱の claude 2.1.263（2026-09-06）は Opus 5.5（2026-09-22 公開）を知らず `unrecognized_model` で CC 工程が全失敗するため、ピンは**未適用（ブロッカー）**。適用には SDK ≥ Opus 5.5 対応版（例 0.3.318 / claude 2.1.318）が必要で、DSH が SDK を完全ピンしているため SDK 上書き or DSH 新リリースの承認待ち。`opus` エイリアスでの代替は 5.5 未満へ黙って落ちる恐れがあるため不採用。CC パッチに init 捕捉を追加し、実効 model/effort を usage 行（`cc_model`/`cc_effort`）に記録、要求 xhigh と違えば notes に downgrade を記録。
- 2026-11-05: box 部分初期化（17:57 頃）で消えた OpenCode 隔離を `bin/factory-oc-provision`（`factory-setup` から冪等実行）で再構築: user factory-oc（uid 1001、admin グループ無し）、`/home/factory-oc`（700、opencode はグローバル @opencode/cli の checksum 一致コピー、opencode.json は model `opencode-go/deepseek-v4.1-flash` + permission `*` allow）、`/etc/sudoers.d/factory-oc-acp`（visudo 検査、launcher のみ root 実行 + env_keep）、`/var/factory/oc-workspaces`。保存 auth は再投入しない（子は launcher が渡す `OPENCODE_API_KEY` のみで認証。キーをディスクに置かない）。pstack OC skills は既存 `factory-pstack-install` が再導入。
- 2026-11-05: **前提: 実行環境を最新に保つ**（user 決定）。DSH / Agent SDK・Claude Code / OpenCode 等は必要なモデル・機能が使えるよう最新化する（docs/design.md §0）。セキュリティ更新方針との整合: 日次は従来どおり security + patch/minor 自動、本体更新は「重大脆弱性」に加え「必要なモデル/機能のための最新化」でも承認つきで実施し、常に factory-update のスナップショット/検証/ロールバックを通す。
- 2026-11-05: Agent SDK を 0.3.263→0.3.318（同梱 claude 2.1.263→2.1.318）に user 承認で更新。DSH 0.2.2-rc.1 の完全ピンは headless プロファイルの `pnpm-workspace.yaml` の `overrides`（SDK 本体 + linux-x64 バイナリ）で上書き（写しは `config/headless.pnpm-workspace.yaml`）。`factory-update apply --approve sdk:claude-agent-sdk@<ver>`（kind `cc-sdk`、プロファイル丸ごとスナップショット）で実施。試行 1/2 は local-dry-run のみ失敗→自動ロールバック（1: 既知の spec 消失、2: 受入れ 13 件が固定閾値 18 未満）。対策: `factory-local-dry-run` が spec をコミットしてから凍結（run-local と同じ）、verify の受入れ基準を「dry run の gate/claude PASS + 受入れ全 OK + 最低 10 件」に変更（件数は CC spec 次第で 13〜34 と揺れるため）。試行 3 で全 PASS。
- 2026-11-05: CC を `claude-opus-5-5` + effort `xhigh` にピン（`config/factory.patch.yml` の model + env `CLAUDE_CODE_EFFORT_LEVEL`、加えて CC パッチで SDK Options.effort を明示）。SDK init は effort を返さないため、CC パッチに Stop hook を追加し実効 effort（ダウングレード後）を usage 行 `cc_effort` に記録。実 pong: cc_model=claude-opus-5-5, cc_effort=xhigh。

- 2026-11-05: **multi OpenCode（IMPL fan-out）** — `FACTORY_OC_PARALLEL`（既定 1、clamp 1..4）で `factory-impl-step` が N 個の隔離 WS + 専用 `FACTORY_OC_HOME` を並列起動し、acceptance 採点で勝者を選ぶ（OC exit 0 → 合格数 → 非空 patch → 低 index）。Candidate B（1 つの DSH plugin 呼び出し内で N activation）は不採用: DSH ACP は one-shot 前提でプロセス隔離も弱い。共有 `/home/factory-oc` 汚染を避けるため per-slot home を追加（未設定時は共有のまま）。WS/`FACTORY_OC_HOME` は realpath で prefix 検査（chown 脱出防止）。tar フォールバックは削除（空/失敗は非ゼロ）。試験: `local/tests/test_impl_parallel.sh`（mock factory-step）。

- 2026-11-05: **IMPL 並列度は CC が SPEC で決める（parallel-first）** — 誰が 1 vs 4 を選ぶかは人間の env ではなく Claude Code。`factory-spec-step` が `spec/IMPL_STRATEGY.md`（先頭 `parallel: N`、1..4 + 短い日英 rationale）を書かせる。`factory-impl-step` の解決順: `FACTORY_OC_PARALLEL`（セット時のみ・試験/緊急上書き）→ `spec/IMPL_STRATEGY.md` → **欠落/不正時既定 2**（parallel-first、stderr 警告）。clamp 1..4。`impl-*-parallel.json` に `parallel_source`（`env`|`spec`|`default`）。FS allowlist は既に `spec/*` 許可。

- 2026-11-07: **OpenCode reasoning effort は `max`（モデル ID ではない）**。ランタイムだけにあった `/home/factory-oc/.config/opencode/opencode.json` の `providers.opencode-go.models.deepseek-v4.1-flash.settings.reasoningEffort=max` を `factory_oc_opencode_json`（`bin/factory-common.sh`）へ移し、`factory-oc-provision` が再プロビジョン時に同じ文書を書く。モデル文字列は `opencode-go/deepseek-v4.1-flash` のまま。`…-max` や root `model` の `#max` は使わない（公式 config/models 文書は root 既定が `#variant` を保持しないと明記。schema は `#variant` 構文自体は許す）。`reasoningEffort` は schema の名前付き列挙ではなく `Config.Model.Settings` の追加プロパティで、[models 文書](https://opencode.ai/docs/models/) が `providers.<id>.models.<id>.settings.reasoningEffort` として示す。models.dev `opencode-go` / `deepseek-v4.1-flash` の effort は `low`/`high`/`max` のみで、別 ID `deepseek-v4.1-flash-max` は無い。`FACTORY_OC_MODEL` がこのモデル以外のときは従来の model+permission だけ（未確認モデルに max を付けない）。`permission: {"*":"allow"}` は維持。新規並列スロットは既存の `seed_oc_home` が共有 `.config/opencode/` をコピーするので追加の伝播機構は無い。既存スロット HOME はスナップショットのまま。セキュリティ更新方針（日次は security + patch/minor 自動、本体は承認）は不変。回帰は `local/tests/test_oc_provision_reasoning.sh`（オフライン。OpenCode は呼ばない。実応答は effort をエコーしないため、生成 JSON の検証に限る）。

## 2026-11-07 — publication provenance（codefctory-grokbot）

公開元はローカル factory HEAD `2da5ab4704b93f23f077b5983231e2a9967aa76d` のサニタイズスナップショット。リモート `yamagen3/codefctory-grokbot` を先に確認した: ブランチは `main` のみ、コミットは `7d316ca347f787b3924fda78fcc6e001f254b67d`（Initial commit、`README.md` のみ）。PR / Issue / 他ブランチは無し。目的の衝突は見当たらないため、この履歴を書き換えずにブランチへ統合した。

ローカル専用としてスナップショットに含めず、リモートにも無かったもの（欠落は削除指示ではない）:

- `local/` 一式。HEAD は `local/pstack-installed-sha` と `local/tests` のソーステスト 10 件を追跡していたが、handoff に従いアーカイブから除外した。この公開はそれらを再構成も削除もしない。今回追加する回帰テストは新規の tracked source であり、欠落した 10 件の代替一覧ではない。
- 未コミットの `plugin/index.js` 5 行（`FACTORY_STALL_TIMEOUT_SEC` で activation timeout を上書き）。公開した plugin は HEAD のまま。リモートに対応物は無かった。
- 未コミットの `targets/README.md` の animal-trendcast 行と、未追跡 `targets/animal-trendcast-scaffold/`（13 ファイル）。所有が未確認のため含めない。リモートに対応物は無かった。決定ログ上の 2026-11-04 animal-trendcast 記述は HEAD の文章として残す。
- ランタイム / env / auth / log / usage / 鍵。鍵は供給されていない。`factory-doctor` の `dummy-for-doctor` と leak-check の `leak-canary` はプレースホルダ。

希望構成のうち、スナップショット時点で既に HEAD にあり今回は変えていないもの: CC `claude-opus-5-5` + effort `xhigh`、Agent SDK `0.3.318`（`config/factory.patch.yml` と `config/headless.pnpm-workspace.yaml`）、IMPL 並列は CC の `spec/IMPL_STRATEGY.md`（欠落時 2、上限 4、`FACTORY_OC_PARALLEL` は上書き）、セキュリティ更新方針。
