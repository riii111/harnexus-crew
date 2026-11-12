# Native版

MoonBit Native移行の後続タスクが参照する、配置・固定版・共通型・比較ハーネスの取り決め。
移行中もTS版を既定のまま残し、Native版は別の開発用生成物として検証する。

## 開発環境

```sh
nix develop            # direnvを使う場合は .envrc が同じ環境を読み込む
moon fmt --check
moon check --deny-warn
moon info              # 公開インターフェース native/**/pkg.generated.mbti を更新する
moon test
moon build --target native --release
HARNEXUS_CREW_NATIVE=$PWD/_build/native/release/build/cmd/main/main.exe bun test test/compat
bun test/compat/cli.ts --native _build/native/release/build/cmd/main/main.exe
HARNEXUS_STORE_PROBE=$PWD/_build/native/release/build/store/probe/probe.exe bun test test/native/store.test.ts
```

CIの `native` ジョブは macOS（macos-15）と Linux（ubuntu-24.04）で同じ手順を実行する。
`lefthook install` で、コミット前に `moon fmt` が走る。

## 固定版

| 項目                      | 版                                                     | 固定の場所                                                  |
| ------------------------- | ------------------------------------------------------ | ----------------------------------------------------------- |
| moon / moonc              | 0.1.20261104 (940aa18) / v0.10.20+65efd5b93            | `flake.nix` が版を名指しし、`flake.lock` が配布元を固定する |
| MoonBitのcore             | ツールチェーンに同梱                                   | 上と同じ。mooncakesの依存はない                             |
| Bun（TS版と比較ハーネス） | 1.4.4                                                  | `package.json`                                              |
| md4c（MB06で同梱）        | v0.6.0 (d4eeb1ace5d0a64d6a1245e97bf9c8105c4f3df7)、MIT | MB06                                                        |
| 比較基準のTS版            | `51af56c5ee443de97e244be1c9eee97ebb34a6ac`             | この文書                                                    |

非同期処理は、ツールチェーン同梱の実験的パッケージ `moonbitlang/core/async` を使う（試作と同じ）。
使うパッケージは `moon.pkg` の `options("allow-experimental-packages": true)` で許可する。
mooncakesの `moonbitlang/async` は使わない。
ツールチェーンを上げるときは、`flake.nix` の版名と、この表と、`moon info` の差分を同じ変更で更新する。

後続のTS修正を基準へ含める場合は、基準SHAと対応する比較事例を一緒に更新する。

## パッケージの境界と担当

ソースは `native/` に置く（`moon.mod` の `source`）。
各タスクは自分のパッケージと `cmd/main` の登録箇所だけを変更する。
共通型の変更が必要なときは、統括が影響する担当を調整してから行う。

| パッケージ        | 内容                                                        | 担当               |
| ----------------- | ----------------------------------------------------------- | ------------------ |
| `shared/failure`  | 利用者へメッセージを返す失敗 `TaskFailed`                   | MB01               |
| `shared/jsonio`   | JSONの読み書き、未知フィールドを残す `Fields`               | MB01               |
| `shared/call`     | 呼び出し結果 `CallOutcome`、応答 `CallAnswer`               | MB01（利用はMB08） |
| `shared/boundary` | ソケット・子プロセスの結果型と失敗型                        | MB01（実装はMB02） |
| `shared/run`      | コマンド実行結果 `CommandRun` と、出力して終了する `finish` | MB01               |
| `sys`             | 最小のC連携（OS種別、fdへの全量書き込み）                   | MB01               |
| `store`           | 状態ファイルの読み書き、`records`、排他ロック、状態の保存先 | MB03               |
| `store/probe`     | `store` を別プロセスで競合させる試験用の実行ファイル        | MB03               |
| `os/unix`         | errno名と説明、fdを閉じる                                   | MB02               |
| `os/socket`       | Unixソケットへ1行を送り、答えを受ける                       | MB02               |
| `os/process`      | 子プロセスの実行（締切・出力上限・プロセス群）              | MB02               |
| `os/testkit`      | 上の試験が使うサーバー・fd数の確認（試験だけが取り込む）    | MB02               |
| `cli`             | 振り分け、usage、クラッシュ報告、`environment`・`state`     | MB05               |
| `which`           | PATH上のコマンド探索（`Bun.which` と同じ結果）              | MB05               |
| `cmd/main`        | 入口。引数と環境変数を `cli` へ渡す                         | MB05               |

後続の新しいパッケージは、次の名前を目安にする。

| タスク | パッケージ                                                             |
| ------ | ---------------------------------------------------------------------- |
| MB04   | `request`、`config`、`environment`、`args`、`template`、`path`、`text` |
| MB06   | `markdown`（md4cのCと同梱ライセンスを含む）                            |
| MB07   | `prwake`                                                               |
| MB08   | `app`                                                                  |
| MB09   | `session`                                                              |
| MB10   | `cloud`                                                                |
| MB11   | `adapter`                                                              |

Cのソースは、それを使うパッケージの `native-stub` に置く。
`sys` へ追加するのは、複数のタスクが共用する最小の関数だけにする。

## 共通型の約束

エラーと値の使い分け:

- 呼び出し側が失敗として処理するものは `raise` する。利用者へそのまま見せる失敗は `TaskFailed`、JSONの形の誤りは `JsonError`。
- 失敗の種類を呼び出し側が分岐する境界は、専用のエラー型を持つ。`LineExchangeFailed.connected` が偽なら未送信、真なら結果不明。`ProcessRunFailed.started` が偽のときだけ、プロセスが実行されていないと確定する。
- 呼び出しの結果（`CallOutcome`）や子プロセスの終わり方（`ProcessEnd`）は失敗ではなく値で返す。結果の種類を増やすと、書き漏らした `match` がコンパイルエラーになる。

JSONの境界:

- 内部は型で持つ。外部のJSONは `Fields` で、既知のメンバーを `take_*` で取り出して型へ変換する。
- 取り出した後に残るもの（`rest`）が未知の部分。要求・設定のように現行が拒否する境界は `reject_unknown` で拒否する。ブリッジの応答や保存状態のように自由な境界は、`rest` を保持し `object_with_extra` で書き戻して、未知のフィールドを落とさない。
- 欠けているメンバーとnullは区別する。nullの意味は境界ごとに決めるため、型付きの取り出しはnullを誤った型として拒否し、`take` は `Some(Null)` を返す。
- JSONの読み込みと文字列化は `jsonio` の自前の実装で、標準の `@json.parse` / `stringify` は使わない（数値の原表記の再出力と、対のないサロゲートの拒否が、JSと異なるため）。読み込んだ値の文字列化は、JSの `JSON.parse` の後に `JSON.stringify` を通した結果と同じにする。数値はdoubleを通し（9007199254740993は9007199254740992、1e400はnull、-0は0）、配列の添字にあたるキーは昇順で先に、他のキーは追加順に並べる。重複キーは最後の値を採る。`jsonio` の試験が、Bun 1.4.4の結果との対応表で固定している。
- 対のないサロゲートのエスケープ（`\ud800`）は、JSと同じく受理し、書き戻すときも同じエスケープで出す。MoonBitの `String` はUTF-16であり、対のないサロゲートも保持できるが、構築できるのは `jsonio` のC連携（`string_from_units`）だけである。保持した文字列の長さ・比較・ハッシュ・連結は通常の文字列と同じ。JSON以外へ出す文字列（標準出力、ハッシュの入力など）は `lossy_text` を通す。UTF-8へ符号化したときにJSが対のないサロゲートをU+FFFDにするのと同じ結果になる。
- `CallAnswer` は結果名を書かれたままの文字列で持つ。`CallOutcome` が知らない名前は未送信として扱わない。

`shared/run` の `finish` は、標準出力、標準エラーの順に書いてから終了コードで終わる。
書き込めなかった結果は成功として返さず、終了コード1にする。

## CLIの入口

`cli::run` が1回の呼び出しを受け、`shared/run` の `CommandRun` を返す。
usageの文面、`-h` と使い方エラー（終了コード2）、成功時のJSON1行（stdout）、`TaskFailed` の出力（`harnexus-crew: メッセージ`、終了コード1）、クラッシュ報告をここだけが持つ。
`TaskFailed` 以外のエラーはクラッシュとして報告する。
環境変数は引数が受理されてから読む。HOMEがないときだけアカウントのホームを調べ、見つからなければクラッシュとして報告する。

後続のコマンド担当は、自分のパッケージと `cli/registry.mbt` の自分の分岐だけを変更する。
まだ移していないコマンド（`adapter` を含む）は「is not available in this native build yet」で終了コード1になり、TS版へは委譲しない。
PATH上のコマンド探索が要る担当（`app` のT3 CLI探索、MB07のpr-wake探索）は、`(String) -> String?` の引数を受け取り、`cli/registry.mbt` の分岐が `@which.in_env(env)` を渡す。
実体は `which` パッケージにあり、相対のPATH要素と空の要素、実行できない通常ファイルの扱いを `Bun.which` に合わせている。
`state --request` も同じ扱いで、`state` の一覧は `launch`・`review`・`cloud-review` の状態ファイルだけを読む（pr-wakeの `watch` は読まない）。

## 要求・設定・環境変数の境界

JSONや文字列から型への変換は副作用を持たない。
ファイルの存在・実パスの確認と、Gitの照会は、呼び出し側が注入する。

| パッケージ    | 提供するもの                                                                                                                                                   |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `environment` | 環境変数 `Env`、App/T3の判定、各種ディレクトリ、call socketとharnexus状態ファイルのパス、実行環境の判定（`detect`）、Cloud・T3での拒否                         |
| `request`     | 起動要求 `LaunchRequest`、レビュー要求 `ReviewRequest`、固定base/headを持つ `ReviewCandidate`、チャットIDの検証、テンプレートへ渡す値、Gitの実行器 `GitRunner` |
| `config`      | テンプレート設定 `task.json` の検査                                                                                                                            |
| `args`        | コマンドの引数。オプション定義と型付きの `Command`。usageの文面と入口の振り分けはMB05                                                                          |
| `template`    | `{name}` の埋め込み規則とリンク先に入れる値の制約。Markdownの判定とリンク解決はMB06                                                                            |
| `path`        | Nodeの `path.posix` と同じ結果の `join`・`normalize`・`dirname`・`resolve`                                                                                     |
| `text`        | `\p{L}`・`\p{N}`、Pythonの空白、JSの `trim` と文字列の順序                                                                                                     |

- `request` の注入は `FileProbe`（存在・ディレクトリ判定・実パス）と `GitRunner`（`shared/boundary` の `CommandOutput` を返す）。非同期の関数型なので、同期の関数も渡せる。Gitは安全フラグ付きの `git -C <checkout>` で、`GIT_NO_LAZY_FETCH=1` を渡す。
- `Env::state_root` が `store::state_directory` の `root` になる。`FileProbe` の存在・ディレクトリ判定・実パスは、`store` の `path_exists`・`is_directory`・`real_path_or_self` で満たせる。
- 保存する要求は、受け取ったメンバーを保つ。`startingBranch` や `displayName` のnullと欠落は区別し、`prUrl` は欠落でもnullで保存する。メンバーの順序は保存しない。
- セッションの保存先は、`LaunchRequest::session_key` と `ReviewRequest::session_key` が返す文字列のSHA256で決まる。JSのUTF-8符号化に合わせて `lossy_text` を通してある。
- 実行環境の判定は2段階。`detect` が環境変数だけで決まる結果か、ソケットへの接続を試す相手を返し、接続できたかどうかで `Detected::socket_accepted` か `Detected::undetermined` を選ぶ。
- `String` の `<` と `compare` は辞書順ではない。JSの並び替えと同じ順序が要るときは `@text.compare_utf16` を使う。
- `text` の文字分類表は、固定したBunの `\p{L}`・`\p{N}` から `test/native/unicode-tables.ts` が生成する。`bun test test/native` が表との一致を確かめる。

## 所有権の境界

- JSONの木: `Json` を受け取った側は変更しない。`Fields::from_json` が複製してから取り出す。
- fd: 作った関数が呼び出し側へ渡すか、同じ関数の中で閉じる。失敗・キャンセル・正常終了のどれでも、渡さなかったfdは作った側が閉じる。
- 子プロセス: 起動した境界が、結果を返すまでプロセス群の終了を保証する。結果を返した後に残るプロセスはない。
- Cへ渡す領域: `#borrow` で借りるだけで、Cは保持しない。Cが返す値は整数（fd、errno）にとどめ、確保した領域を返さない。
- 状態ファイル: 書き込みはMB03の `store` だけが行う。他は読み込みと型への変換を行う。

## 状態保存と排他ロック

`store` は、状態ファイルを書く唯一のパッケージである。
読み書きの失敗は用途で型を分ける。

- ファイル単位の操作は `FileFailed` を `raise` する。`action` が `Sync` のときは、内容は置き換わったがディレクトリの同期に失敗しており、再起動後に残る保証がない。
- `records`・ロック・`save_json` は、利用者へ見せる `TaskFailed` を `raise` する。ファイルの失敗は「cannot write パス (ENOENT)」の形のメッセージにする。
- 同期できなかった操作を成功として返さない。

排他の根拠:

- 新規作成は、一時ファイルに書いて同期してから `link()` で置く。置き先がすでにあれば `link()` が失敗するので、競合した書き手のうち1つだけが、完成した内容で作る。
- 置き換えは、一時ファイルを同期してから `rename()` する。読み手は、古い内容か新しい内容の全体のどちらかを見る。書き手が途中で終了しても、残るのは一時ファイルだけである。
- ロックの保持者は、pid・token・開始時刻を持つ。保持者のpidが死んでいるときだけ、`<ロック>.reap` を排他作成した1つの実行がロックを回収する。この回収用ファイルを残したまま実行が終了した場合、ロックは回収されず、消す手順を示して失敗する。
- 解除は、自分のtokenのロックだけを消す。
- 待機付きロック `with_lock` は `moonbitlang/core/async` の `sleep` で待つため、待っている間も他の非同期処理は進む。

状態の保存先のルート（`$XDG_STATE_HOME/harnexus-crew`）の決定はMB04の担当で、`state_directory` はそのルートを受け取る。

fdはすべてclose-on-execで開く。ロックや一時ファイルのfdが、後から起動する子へ継承されない。

`store` の試験は2種類ある。
単一プロセスの試験は `moon test` が実行する。
競合・強制終了・TS版が書く内容との一致は、`store/probe` を複数起動する `test/native/store.test.ts` が確かめる。

## 試作から取り込んだ資料

一時領域の試作（`/private/tmp/harnexus-crew-moonbit-spike-20261112`）のコードは取り込まない。
次を通常のテスト領域へ収めた。

| ファイル                                   | 内容                                                                                        | 使う担当 |
| ------------------------------------------ | ------------------------------------------------------------------------------------------- | -------- |
| `test/native/boundary-cases.json`          | ソケット11件、プロセス10件の入力と期待。注入を要する事例は `seam` に必要な条件を書いた      | MB02     |
| `test/native/mocks/`                       | 事例が使う模擬サーバー（Bun・Python）と模擬コマンド                                         | MB02     |
| `test/native/markdown-link-judgement.json` | リンク判定63件と候補102件。期待はTS版（Bun 1.4.4）の判定で、md4c v0.6.0の判定と一致していた | MB06     |

`test/native/imported-cases.test.ts` が、件数と参照先の存在を確かめる。

試作で得た設計上の判断のうち、実装に残すものは次のとおり。

- ソケットの接続は非ブロッキングで行い、EAGAIN・EINPROGRESS・EALREADY・EINTRのときは10msずつ待って再試行する。接続・書き込み・EOFまでの受信を一つの締切で囲む。
- execの失敗は、子が書く通知用のパイプで判別する。ただし再execする自身のコピーは使わず、C内でforkしてexecし、結果の判別まで同期して待つ。複数の子を同時に起動しても、通知と書き込み側のfdは起動ごとに閉じるので混ざらない（[os/README.md](os/README.md)）。
- md4cのフラグは、tables・strikethrough・tasklistsに、NOHTMLBLOCKSとNOINDENTEDCODEBLOCKSを加える。原文を直接パースしたときのエスケープ差は、マーカー経路の一致とは別に扱う。
- 試作の性能値（バイナリ約0.6MB、実行時間約2.5ms）は合格値にしない。

## 比較ハーネス

TS版とNative版を別の一時状態で動かして比べる仕組みは、[test/compat/README.md](../test/compat/README.md) にある。

## 配置の規約

MoonBitのファイルは、公開する型と定数、入口となる関数、そこから呼ばれる処理、汎用の補助関数、試験の順に置く。
試験は同じパッケージの `*_wbtest.mbt` に置く。
`AGENTS.md`、`.claude/`、`memo/` はローカル資料であり、追跡しない。
