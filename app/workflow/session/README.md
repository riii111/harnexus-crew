# 起動とローカルレビューの状態遷移

`launch`・`review`（AppとT3 Code）・`state --request`・`resolve`・`name` と、それらが共有するセッションの状態遷移。
Cloudでのレビュー（Codex CLI）と `cloud` コマンドは含まず、`review` が `cloud` 引数で受け取る関数（`cloud` パッケージ）に渡す。

| 公開する関数・型                        | 内容                                              |
| --------------------------------------- | ------------------------------------------------- |
| `launch(args, env, which~)`             | `launch`                                          |
| `review(args, env, which~, cloud~)`     | `review`                                          |
| `show_request_state(path, env, which~)` | `state --request`                                 |
| `resolve(args, env, which~)`            | `resolve`                                         |
| `name(args, env, which~)`               | `name`                                            |
| `check_kept(previous, current, keys)`   | `review` と `cloud-review` の「元の値を保つ」検査 |
| `Ports`、`ports_of(host)`               | Appの呼び出しと状態の保存                         |

`which` は `cli/registry.mbt` の分岐が `@which.in_env(env)` を渡す。
`review` の `cloud` は、`HARNEXUS_EXECUTION_ENV` などが Claude Code のCloudと宣言する場合だけ呼ばれ、それ以外のCloudは `review` の拒否になる。

## セッションの記録

1つのセッションは、`state.json`（確認済みの内容）、`pending.json`（結果が分からない送信）、`history.json`（再実行を諦めた拒否の履歴）を持つ。
保存先は `<state root>/<kind>/<sha256(キー)の先頭16桁>/` で、キーは `launch` が `<projectId>\n<taskId>`、`review` が `<checkout>\n<workerChatId>`。
状態の保存・読み込み・排他作成は `store` が行い、このパッケージは書き込みの順序と内容を決める。

送信の流れ:

1. `pending.json` が残っていれば、送らずに失敗する。残っている理由（結果不明・拒否）と、`resolve` の手順を示す。
2. `pending.json` を `status: "sending"` で排他的に作る。同時に動いた別の実行が先に作っていれば、`another harnexus-crew run is sending; inspect <path>` で失敗し、Appは呼ばない。
3. `state.json` が読み込み時と変わっていれば、記録を消して失敗する。別の実行が状態を書いたため、読み直させる。
4. Appを呼ぶ。答えで分かれる。

| 答え                                                     | 記録                                                     | 結果                                      |
| -------------------------------------------------------- | -------------------------------------------------------- | ----------------------------------------- |
| `done`                                                   | `state.json` を更新し、`pending.json` を消す             | 成功                                      |
| `done` でもスレッドIDが使えない・`state.json` を書けない | `pending.json` を `unknown` にしてスレッドIDと答えを残す | 失敗。`resolve --sent` で確定する         |
| `model_mismatch`・`first_turn_refused`                   | `pending.json` を `refused` にする                       | 失敗。`resolve --not-sent` でだけ解く     |
| `not_sent`・`rejected`・`invalid`・`unsupported`         | `pending.json` を消す                                    | 失敗（未送信）。もう一度送れる            |
| それ以外（`unknown`、未知の結果名など）                  | `pending.json` を `unknown` にして答えを残す             | 失敗。再送せず、Appで確かめるよう案内する |

2つの実行が同時に始まっても、`create_thread` を送るのは1つだけである。
送信中に実行が死んだときの `pending.json`（`sending`）は自動では回収せず、`resolve --sent` または `--not-sent` で解く。
`launch`・`review` はロックファイルを使わず、この排他作成が使用中の判定を兼ねる。
ロックの待機・回収（`store::with_lock`・`acquire`）は、Cloudレビューとアダプターだけが使う。

## 共有する検査

`check_kept` は、前回の候補と今回の候補が指定した項目を保っているかを調べる。
`checkout` は実パスで比べる。
Cloudレビューは `taskId`・`workerAI`・`checkout` を、Appのレビューはさらに `workerChatId`・`projectId` を渡す。

## 試験

- `moon test` の `session`: 模擬のApp・Git・テンプレート・pr-wakeを注入し、実際のファイルへ状態を保存して、送信の順序、排他作成の競合、状態が書き換わった場合、記録を残す失敗、拒否、`resolve`、レビューの継続、`name` を確かめる。
- `test/cases`: `launch-*`、`resolve-*`、`state-request-*`、`name-*`、`review-*` を、期待値と照らす（stdout・stderr・終了コード・状態・Appへの要求・pr-wakeとT3 CLIの呼び出し）。
- `test/test_session.py`: 複数の実行にまたがる流れ（結果不明からの再開、レビューの継続、拒否、送信中に死んだ実行、同時起動）を、同じ期待値と照らす。
