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

## 見る観点（短く）

- diff が `spec/`・`tests/acceptance/`・`.github/` を触っていないか（guard と二重）
- 実装が `PRODUCT.md` の入出力・エラー・stdlib 制約に沿うか
- CI が本当に緑か（`ci.exit`）
- `gate/claude` の PASS/FAIL 理由に明らかな見落としがないか

判定の正本は Git 上の成果物と statuses。agmsg は参考情報のみ。
