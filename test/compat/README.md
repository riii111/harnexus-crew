# 互換性ハーネス

`test/compat/` は、TS版（基準）とNative版を別々の一時ディレクトリで動かし、観測結果の差を返す。

```sh
bun test/compat/cli.ts --native BINARY [--case NAME] [--include-pending]
```

差があれば、`{ field, expected, actual }` の一覧をJSONで出力して終了コード1で終わる。
`bun test test/compat` は、ハーネス自身の試験（意図的な差の検出）と、基準が二つの一時領域で同じ観測結果になることの確認を行う。

## 事例の形式

`test/compat/cases/<name>.json`（ファイル名は `name` と同じ）。
項目の定義は `test/compat/types.ts`。

| 項目                               | 内容                                                                                                                                  |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `owner` / `status`                 | Native版を一致させる担当。`pending` の事例は基準だけで動かし、担当が `active` にした時点でNative版と比較する                          |
| `kind`                             | `command`（1回で答える）、`help`（使い方）、`session`（adapterのように行で往復する）、`inherit`（外部コマンドが標準入出力を引き継ぐ） |
| `argv` / `env` / `stdin` / `steps` | 入力。`steps` は `session` の送信（`send`）と、標準出力が指定行数に達するまでの待機（`wait`）                                         |
| `files` / `seed`                   | 実行前に一時領域へ置く内容。`seed` はリポジトリ内のディレクトリを `target: source` で複製する                                         |
| `bridge`                           | 模擬ブリッジの応答計画。接続ごとの要求を記録し、`drop`（応答せず切断）や `silent`（無応答）も返せる                                   |
| `commands`                         | PATH先頭に置く外部コマンドの模擬。引数と標準入力を記録する                                                                            |
| `snapshot`                         | 比較する状態ディレクトリ（既定は config、state、work、home/.local、home/.config）                                                     |
| `normalize`                        | 事例ごとの置換。`pattern`、`with`、適用先 `scopes` を指定する                                                                         |
| `compare`                          | `stdout` と `stderr` の比較方法（`json`、`lines`、`exact`）。既定は `kind` ごとに決まる                                               |

一時領域は、home、config、state、tmp、work、bin を持つ。
環境変数は PATH、HOME、XDG_CONFIG_HOME、XDG_STATE_HOME、TMPDIR と、事例の `env` だけを渡す。
`env` と `files` では `{{root}}`、`{{bridge}}`、`{{home}}`、`{{config}}`、`{{state}}`、`{{tmp}}`、`{{work}}` が一時領域のパスに展開される。

## 比較と置換の規則

- 標準出力・標準エラー・終了コード・シグナル・保存状態・ブリッジへの要求・外部コマンドの引数と標準入力を比較する。
- JSONは意味で比べる（メンバーの順序は無視）。`lines` は行の数と各行を比べ、2行と1行にまとめた出力を区別する。保存先のパスは文字列のまま比べるため、ハッシュによる状態のキーが変わると差になる。
- 一時領域のパスは常に `<ROOT>` へ置換する。時刻・一意なID・一時パスなどの置換は、事例の `normalize` に、置換する先（`scopes`）を限って書く。
- 置換は値の中の文字列だけを書き換える。要求や外部コマンドの呼び出しを削除・統合・並べ替えないため、重複送信や結果不明は置換後も差として残る。ファイルのパスは置換しない。
- 未知の応答フィールドを保つ契約は、`jsonio` と `call` のMoonBit試験が固定している。

## 担当ごとの使い方

担当は、自分の事例の `status` を `active` にして、Native版が一致することを確認する。
事例は責務別に追加する。TS版の修正が基準に入った場合は、対応する事例の期待が変わる。
模擬ブリッジはUnixソケットを作るため、ソケットの作成を禁じる環境では `bun test test/compat` が動かない。

`cli.ts` は `active` の事例が0件でも成功で終わる。事例を `active` にしたときに、実際に比較されたことは出力の `cases` で確かめる。
