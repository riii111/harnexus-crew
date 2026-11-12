# Cloudレビューと `cloud`

Claude CodeのCloudセッションでの `review` と、`cloud` コマンド。
TS版の `src/task/cloud-review.ts` と `src/task/cli.ts` の `cloud` に対応する。
セッションの共通の検査 `check_kept` は `session` を使い、App・T3 Codeの `review` は含まない。

| 公開する関数                   | TS版          |
| ------------------------------ | ------------- |
| `review(args, env)`            | `cloudReview` |
| `open_chat(args, env, which~)` | `cloud`       |

`review` は `session::review` の `cloud` 引数へ渡す。
実行環境がClaude CodeのCloudと宣言されたときだけ呼ばれ、それ以外のCloudは `session` が拒否する。
`which` は `cli/registry.mbt` の分岐が `@which.in_env(env)` を渡す。

## Cloudレビュー

同じマシンのCodex CLI（`codex exec --json`）をレビュアーとして動かし、その答えをコマンドの結果にする。
App側のようにチャットを作らず、`workerChatId` の既定はClaude Codeのセッション（`CLAUDE_CODE_SESSION_ID`、空なら `cloud`）になる。
`projectId` は使わない。

セッションは `<state root>/cloud-review/<sha256(キー)の先頭16桁>/` に置く。
キーは `<checkout>`・NUL・`<taskId>` で、`checkout` は実パス。

| ファイル       | 内容                                                                                          |
| -------------- | --------------------------------------------------------------------------------------------- |
| `state.json`   | 確認済みの内容: `reviewer`、`candidate`、`verdict`、`heads`、`updatedAt`                      |
| `pending.json` | 結果が分からない実行: `reviewer`、`base`、`head`、`startedAt`。残っていると次のレビューを拒否 |
| `lock.json`    | 実行中のコマンドのpid・token・開始時刻。`ask` も同じロックを取る                              |

レビューの流れ:

1. ロックを待たずに取る。別の実行が保持していれば `another review (pid N) is using this session` で失敗する。死んだ実行のロックは取り上げる。
2. `pending.json` が残っていれば、`--recover discard` がない限り失敗する。`--recover discard` は `pending.json` を消して続ける。残っていないのに指定すると失敗する。
3. 前回の候補があれば、`taskId`・`workerAI`・`checkout` が同じか確かめる。同じ `head` は、レビュアーが判定した後なら拒否する。`判定保留` と判定の行がない答えの `head` は、もう一度送れる。`verdict` を持たない古い状態は判定済みとして扱う。
4. 環境変数 `HARNEXUS_CODEX_BIN`・`HARNEXUS_REVIEW_TIMEOUT_MS`・`HARNEXUS_REVIEW_KILL_GRACE_MS` を検査してから、`pending.json` を書く。時間の2つは2147483648以上でも受理し、TS版のタイマーと同じく1msで扱う。締切が1msになった実行は直ちに停止し、`pending.json` を残す。
5. Codex CLIをチェックアウトの中で実行する。初回は新しいレビュアー（既定は `gpt-6.1-sol`、思考量 `medium`）を `--sandbox read-only` で作り、2回目からは `exec resume` で同じレビュアーを続ける。モデルと思考量は、空文字を未指定として扱う。

実行の結果は次のとおり分かれる。

| 結果                                                                               | 記録                                                             | 結果                                          |
| ---------------------------------------------------------------------------------- | ---------------------------------------------------------------- | --------------------------------------------- |
| 答えがあり、終了コード0、`turn.failed` なし                                        | `state.json` を更新し、`pending.json` を消す                     | 成功                                          |
| 起動できなかった                                                                   | `pending.json` を消す                                            | 失敗。もう一度送れる                          |
| 終了コードが0以外・`turn.failed`・答えなし・スレッドなし                           | `pending.json` を消す                                            | 失敗。もう一度送れる                          |
| 上のうち標準エラーが `no rollout found`（Cloudの再構築でレビュアーの記録が消えた） | `pending.json` を消し、`state.json` の `reviewer` を null にする | 失敗。次のレビューは新しいレビュアーを作る    |
| 締切・出力の上限・起動後の失敗                                                     | `pending.json` を残す                                            | 失敗。確かめてから `--recover discard` で送る |
| 答えは得たが `state.json` を書けなかった                                           | `pending.json` を残す                                            | 失敗。答えをメッセージに添える                |

Codex CLIの出力は、1行1イベントのJSONとして読む。
JSONでない行と、オブジェクトでない行は読み飛ばす。
`thread.started` のスレッドIDは小文字のUUIDだけを受け付け、それ以外が来ると先のIDも消える。
答えは最後の `agent_message` の文、失敗は最後の `turn.failed` の理由で、理由がなければ `the turn failed` とする。

`verdict` は、行頭（空白を挟んでよい）の `判定:` の後の `LGTM`・`修正必要`・`判定保留` のうち、最初に現れたもの。
行頭はJSの `^` と同じく、`\n`・`\r`・U+2028・U+2029の直後を指す。空白はJSの `\s`。

`--ask FILE` は、同じレビュアーへファイルの文を渡し、返事を `kind: "reply"` で返す。
レビュアーを持たないタスク、空のファイル、締切で止まった実行は失敗にする。
`state.json` の `verdict` と `head` は変えず、`pending.json` も作らない。

## `cloud`

Codex AppのブリッジへCloudセッションの `cloud_open` を送り、開いたチャットの情報を返す。
Cloud・T3 Codeでは何も送らずに拒否する。
答えが `done` で `result` がオブジェクトなら、それをそのまま返す。
それ以外は、`unsent` の種類（未送信と分かるもの）なら `nothing was sent`、そうでなければ `never resend; check the app` を添えて失敗にする。
カレントディレクトリ（`cwd`）を添えて送る。

## TS版との差

- 非文字列の `workerChatId`（null・数値・配列など）は、プロンプトにはJSの `String(値)` の形で入れ、保存する候補には入力のまま残す。TS版と同じ。
- 2147483648以上の時間で、TS版が標準エラーへ書くBunの `TimeoutOverflowWarning` は、Native版では書かない。比較事例は、この警告だけを置換して比べる。
- カレントディレクトリを読めないとき、`cloud` は `cannot read the current directory` で失敗する。TS版は例外で終わる。

## 試験

- `moon test` の `cloud`: Codex CLIの代役 `test/native/mocks/fake-cli.sh` を実際の子プロセスとして動かし、Gitとテンプレートは差し替える。初回と再レビュー、判定済みの `head`、実行の失敗と停止、保存できなかった答え、`ask`、ロック、`harnexus-task` が残した状態（`test/fixtures/legacy-state/cloud`）の継続を確かめる。
- `test/compat/cases/cloud-review-*`: 1回の実行の結果を、Codex CLIの出力を変えながらTS版と比べる。
- `test/compat/cases/cloud-*`（ブリッジを使う事例）: `cloud` コマンドの要求・答え・失敗をTS版と比べる。
- `test/native/cloud.test.ts`: 複数回の実行にまたがる流れ（再レビュー、停止からの復旧、`ask`、ロックの取り上げ、保存済みの状態の継続）をTS版と同じ根で動かして比べる。
