# 受入試験

リリースビルドの `harnexus-crew` を外側から動かし、利用者から見える契約を確かめる。
実行器はPythonの標準ライブラリだけで書いてあり、Bunもtypescriptも使わない。

```sh
moon build --target native --release
python3 test/parallel.py            # 3つのプロセスに分けて同時に動かす（-j で数を変える）
python3 -m unittest discover -s test # 1つのプロセスで順に動かす
```

実行ファイルの場所は `test/harness/binaries.py` が決める。
既定は `_build/native/release/build/` の下で、`HARNEXUS_CREW_NATIVE`・`HARNEXUS_STORE_PROBE`・`HARNEXUS_MARKDOWN_PROBE`・`HARNEXUS_PROMPT_PROBE` で替えられる。
実行ファイルがなければ、試験は飛ばさず失敗する。
模擬のブリッジはUnixソケットを作るため、ソケットの作成を禁じる環境では動かない。

## 構成

| 場所                    | 内容                                                                                                                    |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `test_cases.py`         | `cases/` の事例を1件ずつ動かし、`expected/cases/` の期待値と照らす                                                      |
| `test_session.py`       | `launch`・`review`・`state`・`resolve`・`name` の複数回の実行。結果不明からの再開、同時起動                             |
| `test_cloud.py`         | Cloudレビューの複数回の実行。再レビュー、停止からの復旧、`ask`、ロックの取り上げ                                        |
| `test_adapter.py`       | `adapter serve` を実プロセスで動かし、応答の行、入力の終了、往復後のfd数を確かめる                                      |
| `test_store.py`         | `test/probes/store` を複数起動し、ロック・原子的な書き込みの競合と途中終了を確かめる                                          |
| `test_prompt.py`        | `test/probes/prompt` でテンプレートの展開とリンクの拒否を確かめる                                                             |
| `test_markdown.py`      | `test/probes/markdown` でMarkdownのリンク判定を確かめる                                                                       |
| `test_install.py`       | `scripts/install.sh` の実ビルド1回、入れ子prefixへの設置、失敗時の既存バイナリの保持                                    |
| `test_harness.py`       | 実行器自身。意図した差を見つけること、重複した要求や結果不明を隠さないこと                                              |
| `harness/`              | 実行器。一時領域、模擬のブリッジ、模擬コマンド、観測、置換、比較                                                        |
| `fixtures/`             | テンプレートの試験用skill                                                                                               |
| `native/`               | リンク判定と保存内容の事例、`moon test` が使う模擬コマンド                                                              |

## 事例

`cases/<name>.json`（ファイル名は `name` と同じ）。項目の定義は `harness/cases.py`。

| 項目                               | 内容                                                                                                                                  |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `kind`                             | `command`（1回で答える）、`session`（adapterのように行で往復する）                                                                    |
| `argv` / `env` / `stdin` / `steps` | 入力。`steps` は `session` の送信（`send`）と、標準出力が指定行数に達するまでの待機（`wait`）                                         |
| `files` / `seed`                   | 実行前に一時領域へ置く内容。`seed` はリポジトリ内のディレクトリを `target: source` で複製する                                         |
| `git`                              | 実行前にサンドボックスの根で順に走らせる git の引数。日付とコミッターが固定されるため、同じ手順なら同じコミットになる                 |
| `bridge`                           | 模擬ブリッジの応答計画。接続ごとの要求を記録し、`drop`（応答せず切断）や `silent`（無応答）も返せる                                   |
| `commands`                         | PATH先頭に置く外部コマンドの模擬。引数と標準入力を記録する。標準入力は、閉じられるまで読む                                           |
| `snapshot`                         | 比較する状態ディレクトリ（既定は config、state、work、home/.local、home/.config）                                                     |
| `compare`                          | `stdout` と `stderr` の比較方法（`json`、`lines`、`exact`）。既定は `command` が `json`、`session` が `lines`、`stderr` は `exact`     |

一時領域は、home、config、state、tmp、work、bin を持ち、事例ごとに空から作る。
環境変数は PATH、HOME、XDG_CONFIG_HOME、XDG_STATE_HOME、TMPDIR と、事例の `env` だけを渡す。
`env`、`files`、`bridge`、`steps` の `send` と `git` では `{{root}}`、`{{bridge}}`、`{{home}}`、`{{config}}`、`{{state}}`、`{{tmp}}`、`{{work}}` が一時領域のパスに展開される。

## 照合と置換の規則

- 標準出力・標準エラー・終了コード・シグナル・保存状態・ブリッジへの要求・外部コマンドの引数と標準入力を照らす。
- JSONは意味で比べる（メンバーの順序は無視。真偽値と数値は別）。`lines` は行の数と各行を比べ、2行と1行にまとめた出力を区別する。
- 一時領域のパスは常に `<ROOT>` へ置換する。シナリオでは、この試験を動かしているチェックアウトのパスも `<REPO>` へ置換する。
- ミリ秒付きのISO時刻（`2026-11-13T01:02:03.000Z`）は、標準出力・標準エラー・保存状態で常に `<TIME>` へ置換する。
- 保存状態の取り込みでは `.git` の中を読まない。中身はgitの版で変わり、CLIの状態ではない。
- 置換は値の中の文字列だけを書き換える。要求や外部コマンドの呼び出しを削除・統合・並べ替えないため、重複送信や結果不明は置換後も差として残る。ファイルのパスは置換しない。
- 未知の応答フィールドを保つ契約は、`app` の `call_answer` のMoonBit試験が固定している。

## 期待値

`expected/` は、基準のTS版（コミット `51af56c5ee443de97e244be1c9eee97ebb34a6ac`、Bun 1.4.4）に同じ事例とシナリオを動かして得た観測を固定したもので、TS版は撤去済みである。
`expected/cases/` が事例、`expected/scenarios/` が `test_session.py`・`test_cloud.py` のシナリオに対応する。

状態のキーは、一時領域のパスから作られるものがある。
期待値は、キーの代わりに `{{key:N}}` を置き、`keys[N]` に元の文字列（一時領域は `<ROOT>`）と桁数を持つ。
照合のたびに、実際の一時領域でそのSHA-256を計算して戻すため、キーの作り方を変えれば差になる。

期待値に手を入れたのは次の2点だけである。

- Bunが標準エラーへ書く `TimeoutOverflowWarning` は、期待値から除いた。Native版は書かない。
- `cloud-review-takeover-died` の死んだプロセスのIDは、実行ごとに違うため `<DEAD_PID>` と書いた。

契約を変えるときは、期待値と事例を同じ変更で更新する。

## 既知の差

- 起動時にカレントディレクトリを読めないとき、TS版は例外で終わり、Native版は `cannot read the current directory` で失敗する。この診断は期待値に含めていない。
- 応答待ちの要求が残ったまま `adapter serve` の入力が閉じると、TS版は40秒以上止まってロックを残す。Native版は、要求が終わるのを待って終了する。この条件は、TSと一致した事例に数えていない。`test_adapter.py` と `app/workflow/adapter` の試験が、Native版の挙動を確かめる。
