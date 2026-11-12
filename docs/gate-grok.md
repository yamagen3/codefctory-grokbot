# gate/grok — Grok 第二ゲートの回し方

## 役割

`gate/claude` のあとに独立レビューする。通れば `factory-merge` が可能（他 3 チェックも success のとき）。

## ローカルでの流れ

1. オーケストレータが `factory-gate-grok <repo> <id>` を呼ぶ。
2. `local/grok-hooks/bundle-<sha>/` にレビュー束が出来る:
   - `PRODUCT.md` / `OPEN_QUESTIONS.md`
   - `diff.patch` / `diff.stat.txt`（`spec/<id>`…HEAD — 直近 freeze 以降）
   - `diff.full.patch` / `diff.full.stat.txt` / `diff.full.meta.txt`（`merge-base(origin/main, HEAD)`…HEAD — ブランチ全体）
   - `ci.out` / `ci.exit`
   - `statuses.json` / `gate-claude.json`
   - `README.md`（手順）
3. あなた（Grok）が束を読み、判定を記録する:
   ```bash
   factory-gate-grok record <sha> success "仕様と一致。stdlib のみ。"
   # または
   factory-gate-grok record <sha> failure "受入れの空セル仕様を満たさない"
   ```
4. `wait` モードならオーケストレータが result ファイルを検知して続行する。

## モード

| 環境変数 | 動作 |
|---|---|
| （なし）+ `FACTORY_GROK_STUB=pass\|fail` | 自動テスト用 stub |
| `FACTORY_GROK_MODE=wait` | 束を書き、result を待つ（既定、stub 無し時） |
| `FACTORY_GROK_MODE=pending` | 束だけ書いて exit 2（外側で poll） |
| `FACTORY_GROK_WAIT_SEC` | 待ち上限秒（既定 3600） |
| `FACTORY_GROK_ON_WAIT_TIMEOUT` | `wait` の待ち時間切れ時の扱い。`park`（既定）は pending に戻して exit 2、`fail` は error にして終了 |

`wait` が待ち時間切れになったとき、既定の `park` では pending レコードを `mode="pending"` に書き換えて `parked_at` を付け、status を `pending`（`awaiting Grok (wait timed out)`）に戻して exit 2 する。外側の poll はそのまま続けられる。`fail` では `error` にして終了する（exit 1）。

## 通知

`pending` モードと `wait` の待ち時間切れ（`park`）では `factory-notify grok-pending` を送る。メッセージには `id` / `sha` / `bundle` が入り、待ち時間切れのときは `reason=wait-timeout` が付く。

## SHA の指定（prefix）

`record` には 7 文字以上の SHA 前方一致を渡せる。`local/grok-hooks/pending-<sha>.json` が一意に見つかれば、ファイル名から full SHA に展開して result / status / continue をその SHA で扱う。複数の pending が一致した場合はエラー。pending が見つからない場合は `WARN no pending record for <sha>; nothing will continue` を stderr に出し、記録だけして exit 0（続行しない）。

## 自動続行

`record` は既定で `factory-continue <sha>` を呼び、`pending` モードの判定が success なら `factory-merge` まで自動で進む。`FACTORY_GROK_AUTO_CONTINUE=0` を設定すると自動続行を止められる（あとから手動で `factory-continue <sha> [--force]` を実行できる）。`factory-continue` の終了コードは 0 = マージ済み／続行対象外／続行済み、1 = pending が無い・`factory/<id>` が `<sha>` から移動・マージ失敗、2 = 判定がまだ無い、4 = Grok が拒否（`grok-rejected` を通知）。`wait` / `stub` の pending は既定では続行せず、`--force` を付けたときだけ続行する。

一度 `failure` を記録して `continued-<sha>.json` が `rejected` になっていても、その後に `success` を記録すると再び続行対象になり、成功が拒否を上書きする。

## 見る観点（短く）

- diff が `spec/`・`tests/acceptance/`・`.github/` を触っていないか（guard と二重）
- 実装が `PRODUCT.md` の入出力・エラー・stdlib 制約に沿うか
- CI が本当に緑か（`ci.exit`）
- `gate/claude` の PASS/FAIL 理由に明らかな見落としがないか

判定の正本は Git 上の成果物と statuses。agmsg は参考情報のみ。
