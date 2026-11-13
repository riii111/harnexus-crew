# AppとT3 Codeの接続

Codex AppのブリッジとT3 Codeの `t3` CLIへ、タスクの操作を送る層。
セッションの状態遷移は持たず、呼び出しの結果を `CallAnswer` で返すだけにとどめる（状態遷移は `session`）。

| 公開する関数・型                                                |
| --------------------------------------------------------------- |
| `call_app(env, caller, tool, args, timeout_ms?)`                |
| `host_of(env, which~)` と `Host`                                |
| `project_at(result, directory)`                                 |
| `TurnSettings`、`refusal_of`                                    |
| `CloudReview`、`reviews_in`、`review_text`、`reviewer_ask` ほか |

ソケットのパス、App/T3の判定、呼び出し元のチャットIDは `environment` と `request` を使う。
`call_app` と、`Host` の `call` が使う `call_t3` は失敗を例外にせず、結果の種類を `CallAnswer` に入れて返す。

## 契約

`call_app`:

- 変更を伴う呼び出しの前に、能力照会 `{version:1, query:"capabilities"}` を送る。照会の失敗は、どれも未送信（`not_sent`）になる。
- 照会の答えがプロトコル1の `done` で `operations` を持たなければ、旧ブリッジとして `unsupported` にする。プロトコル1以外へ送り直さない。
- 呼び出す操作が `operations` にない場合は、何も送らず `unsupported` にする。
- 呼び出しの接続前の失敗は `not_sent`、接続後の失敗と締切は `unknown`。
- 答えは枠のための `version` だけを除き、他のメンバーをそのまま保つ。結果名が未知でも落とさない。

`call_t3`:

- 対応する操作は `create_thread` と `send_message_to_thread` だけで、他は `unsupported`。
- `t3` が走る前に決まる拒否（思考量、送信時のモデル・思考量、必須項目の欠け）は、`t3` を起動しない。
- `t3` の失敗は、標準エラーが「サーバーに届く前」または「何も残していない」と示すものだけ `not_sent`。ほかは `unknown`。
- 締切（開始3分、送信1分、照会30秒）と16MiB超えは、結果不明の `unknown`。
- `t3` は `HARNEXUS_T3_BIN`、PATH上の `t3`、T3 Codeの `bin/t3` の順で探す。PATH探索は呼び出し側が `which` で渡す。

`Host`: AppとT3 Codeの違い（スレッド変数、worktreeの置き場、既定の思考量、返信テンプレート、スレッド名の変更可否、レビュー用プロジェクトの決め方）を一箇所にまとめる。

## 補足

- `which`（PATH上のコマンド探索）は注入する。実体は `cli` が、`prwake` のpr-wake探索と共用で用意する。
- `CallAnswer::to_json` は、ブリッジが書いた位置に `outcome` を置く。以前は常に最後へ移り、`list_projects failed: {...}` などの表示が変わっていた。
- 共有の `store` から `sha256_hex` を公開した。Cloudレビューの `key` は、reviewer・head・質問時刻・答えのSHA-256の先頭32桁。

## 試験

`moon test` の `app` が、次を実際のプロセスとソケットで確かめる。

- `call_wbtest.mbt`: 模擬ブリッジ（Unixソケット）で、能力照会、旧ブリッジ、未提供の操作、無応答、切断、ソケットなし・off・相対パス。
- `t3_wbtest.mbt`: 模擬CLI `test/native/mocks/fake-cli.sh` で、起動・送信の引数と標準入力、未送信と結果不明の分類、締切後の結果不明、`HARNEXUS_T3_BIN` と `which` の探索、T3固有のモデル・思考量の拒否。
- `reviews_wbtest.mbt`: 固定した `key` と抽出結果との一致。

ソケットの試験は、ソケットの作成を禁じる環境では動かない。
