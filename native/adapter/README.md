# harnexusアダプター

harnexusのブリッジが起動し、標準入出力の1行1メッセージで話す `adapter` コマンド。
TS版の `src/integrations/harnexus/` に対応する。
入口は `adapter::run` だけで、`cli/registry.mbt` の `adapter_run` が呼ぶ。

| サブコマンド                | 内容                                             | TS版                       |
| --------------------------- | ------------------------------------------------ | -------------------------- |
| `adapter serve --id ID`     | ブリッジの接続を、標準入力が閉じるまで受け持つ   | `command.ts`、`adapter.ts` |
| `adapter handover`          | 観測だけの間に記録したレビューを、待ち行列へ移す | `handOver`                 |
| `adapter export-links`      | `cloud` コマンドが記録したチャットを書き出す     | `cloud-links.ts`           |
| `adapter import-links FILE` | 書き出したチャットを書き戻す                     | `cloud-links.ts`           |

| ファイル           | 内容                                                                   | TS版              |
| ------------------ | ---------------------------------------------------------------------- | ----------------- |
| `adapter.mbt`      | 1行ごとの処理。予約、待ち行列、チャットの開設、履歴、質問の取り次ぎ    | `adapter.ts`      |
| `serve.mbt`        | 標準入力の読み取り、行ごとの並行処理、標準出力と標準エラーへの書き出し | `command.ts`      |
| `review_store.mbt` | Cloudレビューとチャットのフォルダ（`cloud-reviews`）                   | `review-store.ts` |
| `observations.mbt` | 観測位置、待ち行列、最初のレビューの記録、ジャーナル                   | `observations.ts` |
| `links.mbt`        | `export-links`、`import-links`                                         | `cloud-links.ts`  |
| `handover.mbt`     | `handover` とジャーナルの読み取り                                      | `adapter.ts`      |

レビューの型と表示（`CloudReview`、`reviews_in`、`review_text` ほか）は `app` を使い、ここでは作り直さない。
保存先のパスは `environment`、ファイルとロックは `store` を使う。
`adapter serve` の引数は `args::parse_adapter_serve` が読む。`--help` は受け付けない。

## 並行処理

- 受信した1行ごとに、それぞれのタスクで処理する。応答待ちの要求があっても、次の行を読む。
- 応答 `response` は、行を読んだ時点でその場で待っている要求へ渡す。入力の終了が応答を追い越さない。
- 共有の記録を変える処理（レコードの取り込み、待ち行列の消化、最初のレビューの提示）は、届いた順に1つずつ実行する。
- 標準出力と標準エラーは、1行を書き終えるまで他のタスクに書かせない。行が混ざらない。
- 要求の番号は `harnexus-crew-N`。応答は番号で待っている要求へ届く。

## 入力が閉じたとき

標準入力が閉じると、処理中の行がすべて終わってから終了コード0で終わる。

- 応答待ちの要求は、結果不明の `unknown` で終える。送ったかもしれないので、レビューは表示済みとして扱い、再送しない。
- 閉じた後に始める要求は、ブリッジへ送らず `not_sent`（理由 `closed`）で終える。レビューは待ち行列に残り、次の接続で再び試す。
- 応答の書き出しや、ブリッジが待つ `observed` の送信は、閉じた後も行う。

TS版は、応答待ちの要求が残ったまま入力が閉じると、終了せずに止まる。
この差は意図したものである。

## 保存先と形式

TS版と同じファイルを、同じ形式で読み書く。

- `<harnexusの状態>/cloud-reviews/`: `chats.json`、レビューごとの `<key>.json` と予約 `<key>.reserved`、質問の記録 `asked-*.json`
- `<状態のルート>/cloud-observe/`: `sessions/<id>.json`、`pending.json`、`opening/<hash>.json`、`journal.jsonl`、`locks/`
- `<状態のルート>/cloud-chats/<session>.json`: `export-links`、`import-links` の対象

待ち行列に `handover` が移すレビューは、ジャーナルにあるとおりに書く。メンバーの追加や並べ替えをしない。

## 試験

| 場所                               | 内容                                                                                                         |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `*_wbtest.mbt`（`moon test`）      | 模擬ブリッジとの往復。TS版の試験の事例、同時要求、入力の終了、応答の順序、複数回の往復後のfd                 |
| `test/cases/adapter-*.json`        | TS版の出力を固定した期待値との照合。使い方、`export-links`、`import-links`、`handover`、`serve` の観測・書き込み・質問・再開の往復 |
| `test/test_adapter.py`             | 実際のプロセス。400件を一度に送った応答の行、応答待ちの要求を残した入力の終了、160回の往復後のfd数           |
