# 開発とアーキテクチャ

MoonBit Nativeで書かれたCLIの、配置・固定版・共通型・受入試験の取り決め。

## 開発環境

```sh
nix develop            # direnvを使う場合は .envrc が同じ環境を読み込む
moon fmt --check
moon check --deny-warn
moon info              # 各パッケージの pkg.generated.mbti を更新する
moon test
scripts/check-c.sh     # 自作Cの整形・警告・静的解析（clang-format・clang-tidy）
scripts/test-sanitized.sh  # AddressSanitizer・UndefinedBehaviorSanitizer付きで moon test を実行する
moon build --target native --release
python3 -m unittest discover -s test
```

`python3 -m unittest discover -s test` は、リリースビルドの実行ファイルを外側から動かす受入試験で、[test/README.md](../test/README.md) に説明がある。
別のビルドを試すときは、`HARNEXUS_CREW_NATIVE`・`HARNEXUS_STORE_PROBE`・`HARNEXUS_MARKDOWN_PROBE`・`HARNEXUS_PROMPT_PROBE` で実行ファイルを指す。

CIの `native` ジョブは macOS（macos-15）と Linux（ubuntu-24.04）で同じ手順を実行する。
macOSではsanitizer付きの試験が終わらなかったため、`scripts/test-sanitized.sh` はLinuxだけで実行する。
`lefthook install` で、コミット前に `moon fmt` と、自作Cへの `clang-format` が走る。

自作Cの検査は、`moon` がCコンパイラへ渡すフラグに `-Wall -Wextra -Wconversion` を加えて行い、警告はすべて失敗にする。
md4cの `md4c.c`・`md4c.h` は配布元のまま保つため、整形と検査の対象から外す。

## 固定版

| 項目                      | 版                                                                                                              | 固定の場所                                                  |
| ------------------------- | --------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| moon / moonc              | 0.1.20261104 (940aa18) / v0.10.20+65efd5b93                                                                     | `flake.nix` が版を名指しし、`flake.lock` が配布元を固定する |
| MoonBitのcore             | ツールチェーンに同梱                                                                                            | 上と同じ。mooncakesの依存はない                             |
| Python（受入試験の実行器） | nixpkgsの `python3`（標準ライブラリだけを使う）                                                                 | `flake.nix` が名指しし、`flake.lock` が配布元を固定する     |
| md4c                      | v0.6.0（タグ d4eeb1ace5d0a64d6a1245e97bf9c8105c4f3df7、コミット 7fc1815a5eeba2af7d6120a76202bf59f3b6e6e4）、MIT | `share/markdown/` の `md4c.c`・`md4c.h`・`md4c-LICENSE.md` |
| 期待値の元になったTS版    | `51af56c5ee443de97e244be1c9eee97ebb34a6ac`（Bun 1.4.4で実行）                                                    | [test/README.md](../test/README.md)                         |

非同期処理は、ツールチェーン同梱の実験的パッケージ `moonbitlang/core/async` を使う。
使うパッケージは `moon.pkg` の `options("allow-experimental-packages": true)` で許可する。
mooncakesの `moonbitlang/async` は使わない。
ツールチェーンを上げるときは、`flake.nix` の版名と、この表と、`moon info` の差分を同じ変更で更新する。

TS版は撤去済みで、期待値は固定したまま使う。契約を変える場合は、期待値と対応する事例を同じ変更で更新する。

## パッケージの境界

`moon.mod` の `source = "."` により、リポジトリ直下からのパスがパッケージ名になる。

```text
cmd/main/          実行ファイルの入口
app/
  cli/             引数の解析、振り分け、標準入出力、結果の表示
  workflow/        起動・レビュー・復旧の進行、要求の検証、プロンプトの生成
  infra/           外部サービスとの通信、Git、実行環境の取得、状態の永続化
share/             汎用のOS操作、パス・文字列・JSON処理、共通の失敗型
test/probes/       受入試験から起動する補助プログラム
```

製品コードの依存は `cmd → app/cli → app/workflow → app/infra → share` の順に向ける。
下位を直接使う依存もあるが、逆向きには依存しない。
試験だけの依存はこの制限に含めない。

| 場所 | 担当 |
| --- | --- |
| `app/cli/args` | オプションの解析と使い方エラー。workflowの入力型へ変換する |
| `app/cli/adapter` | `adapter serve` の引数、標準入出力と行の分割 |
| `app/workflow` | コマンドの入力型、HOMEの必須判定、Cloud・T3での操作制限 |
| `app/workflow/session` | ワーカー起動、ローカルレビュー、復旧、名前変更の状態遷移 |
| `app/workflow/cloud` | CloudレビューとCloudチャットを開く処理 |
| `app/workflow/adapter` | レビューの取り込み・表示・再開と接続の状態遷移 |
| `app/workflow/request` | 要求の項目・参照先・レビュー候補の検証とテンプレートへ渡す値 |
| `app/workflow/prompt` | 設定の検証、テンプレートのリンク解決と値の埋め込み |
| `app/workflow/host` | App/T3ごとの既定値、返信先、レビューの抽出と表示 |
| `app/workflow/watch` | `watch` の操作選択とGitHub PR URLの判定 |
| `app/workflow/status` | 保存状態の一覧と実行環境の照会 |
| `app/infra/bridge` | Appブリッジ・T3 CLIとの通信と応答型 |
| `app/infra/git` | 安全フラグ付きGitの実行 |
| `app/infra/environment` | 環境変数、保存先、接続先、実行環境の判定 |
| `app/infra/store` | ファイルの読み書き、状態の保存、排他ロック |
| `app/infra/prwake` | pr-wake CLI・エンジンの呼び出し |
| `app/infra/which` | PATH上の実行ファイル探索 |
| `share/os`・`share/sys` | ソケット、子プロセス、errno、最小のC連携と試験用OS操作 |
| `share/markdown` | md4cによるMarkdownのリンク判定 |
| `share/path`・`share/text`・`share/jsonio` | パス・文字列・JSONの処理 |
| `share/failure`・`share/boundary`・`share/run` | 失敗とOS操作の結果型、標準出力・標準エラーと終了コード |

要求をJSONから読む際の項目検査と製品の検証は、診断の順序を保つため `workflow/request` にまとめる。
Gitやファイルを実際に操作する部分はinfraを使い、CLIのパーサには依存しない。
送信するか、結果不明の記録を残すか、再実行を許すかはworkflowが決め、infraは指示された操作を行う。

Cのソースは、それを使うパッケージの `native-stub` に置く。
`share/sys` には複数のパッケージが共用する最小の関数を置く。

## 共通型の約束

エラーと値の使い分け:

- 呼び出し側が失敗として処理するものは `raise` する。利用者へそのまま見せる失敗は `TaskFailed`、JSONの形の誤りは `JsonError`。
- 失敗の種類を呼び出し側が分岐する境界は、専用のエラー型を持つ。`LineExchangeFailed.connected` が偽なら未送信、真なら結果不明。`ProcessRunFailed.started` が偽のときだけ、プロセスが実行されていないと確定する。
- 呼び出しの結果（`infra/bridge` の `CallAnswer`）や子プロセスの終わり方（`ProcessEnd`）は失敗ではなく値で返す。

JSONの境界:

- 内部は型で持つ。外部のJSONは `Map` を直接読み、既知のメンバーを型へ変換する。要求・設定のように現行が拒否する境界は、未知のメンバーを拒否する。ブリッジの応答や保存状態のように自由な境界は、未知のメンバーを残して書き戻す。
- 欠けているメンバーとnullは区別する。nullの意味は境界ごとに決める。
- JSONの読み込みは `@jsonio.parse` で、標準の `@json.parse` の前に、対のないサロゲートのエスケープ（`\ud800`）を `\ufffd` に置き換える。標準の読み込みは、そのエスケープ1つで文書全体を拒否するが、JSの `JSON.stringify` はそれを書くため。読み込んだ文字列はすべてUTF-8へ符号化できる。
- 文字列化は標準の `stringify` を使う。数値の表記とメンバーの順序は契約にしない。保存する状態は1段1空白で字下げする。
- `CallAnswer` は結果名を書かれたままの文字列で持つ。未送信と扱うのは `not_sent`・`rejected`・`invalid`・`unsupported` だけで、知らない名前は未送信として扱わない。

`share/run` の `finish` は、標準出力、標準エラーの順に書いてから終了コードで終わる。
書き込めなかった結果は成功として返さず、終了コード1にする。

## CLIの入口

`cli::run` が1回の呼び出しを受け、`share/run` の `CommandRun` を返す。
usageの文面、`-h` と使い方エラー（終了コード2）、成功時のJSON1行（stdout）、`TaskFailed` の出力（`harnexus-crew: メッセージ`、終了コード1）、クラッシュ報告をここだけが持つ。
`TaskFailed` 以外のエラーはクラッシュとして報告する。
環境変数は引数が受理されてから読む。HOMEがなければ、ホームを使うコマンドは `TaskFailed` で失敗する。

`app/cli/registry.mbt` の分岐が、コマンドごとのパッケージを呼ぶ。
PATH上のコマンド探索が要るパッケージ（`infra/bridge` のT3 CLI探索、`infra/prwake` のpr-wake探索）は、`(String) -> String?` の引数を受け取り、`app/cli/registry.mbt` の分岐が `@which.in_env(env)` を渡す。
実体は `which` パッケージにあり、相対のPATH要素と空の要素、実行できない通常ファイルの扱いを `Bun.which` に合わせている。
`state --request` は `session` が扱い、`state` の一覧は `launch`・`review`・`cloud-review` の状態ファイルだけを読む（pr-wakeの `watch` は読まない）。

## 要求・設定・環境変数の境界

JSONや文字列から型への変換は副作用を持たない。
ファイルの存在・実パスの確認と、Gitの照会は、呼び出し側が注入する。

| パッケージ    | 提供するもの                                                                                                                                                   |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `environment` | 環境変数 `Env`、App/T3の判定、各種ディレクトリ、call socketとharnexus状態ファイルのパス、実行環境の判定（`detect`）                         |
| `request`     | 起動要求 `LaunchRequest`、レビュー要求 `ReviewRequest`、固定base/headを持つ `ReviewCandidate`、チャットIDの検証、テンプレートへ渡す値 |
| `args`        | コマンドの引数。オプション定義と型付きの `Command`。usageの文面と入口の振り分けは `cli`                                                                        |
| `template`    | `{name}` の埋め込み規則とリンク先に入れる値の制約。Markdownの判定は `markdown`、リンク解決は `prompt`                                                          |
| `path`        | Nodeの `path.posix` と同じ結果の `join`・`normalize`・`dirname`・`resolve`                                                                                     |
| `text`        | ASCII英数字、JSの `\s` の空白と `trim`、エラーに添える出力の切り詰め、文字列の順序                                                                              |

- `request` の注入は `FileProbe`（存在・ディレクトリ判定・実パス）と `infra/git` の `GitRunner`（`share/boundary` の `CommandOutput` を返す）。非同期の関数型なので、同期の関数も渡せる。実機の分は `FileProbe::of_machine` と `infra/git` の `Git::of_env` が作る。Gitは安全フラグ付きの `git -C <checkout>` で、`GIT_NO_LAZY_FETCH=1` を渡す。
- `Env::state_root` が `store::state_directory` の `root` になる。
- 保存する要求は、受け取ったメンバーを保つ。`startingBranch` や `displayName` のnullと欠落は区別し、`prUrl` は欠落でもnullで保存する。メンバーの順序は保存しない。
- セッションの保存先は、`LaunchRequest::session_key` と `ReviewRequest::session_key` が返す文字列のSHA256で決まる。
- 実行環境の判定は2段階。`detect` が環境変数だけで決まる結果か、ソケットへの接続を試す相手を返し、接続できたかどうかで `Detected::socket_accepted` か `Detected::undetermined` を選ぶ。
- `String` の `<` と `compare` は辞書順ではない。JSの並び替えと同じ順序が要るときは `@text.compare_utf16` を使う。

## テンプレートとMarkdown

`prompt::task_prompt` が、設定 `task.json`（`templates.worker`・`templates.reviewer` に絶対パス）を検査し、その指すテンプレートを読み、リンクを解決し、値を埋め込んだ文字列を返す。
`prompt::check_templates` が `check` の出力を作る。
TS版と同じく、実在しないファイルや、値の入りうる位置が名前でないリンク先は、送信前に失敗させる。

リンクかどうかはmd4cが決める。
`](...)` の中身を一意なマーカーへ置き換えたテンプレートをmd4cで読み、リンクまたは画像の宛先になったマーカーの候補だけを解決する。
コードやコメントの例、見出しなどで区切られた文は、リンクとして扱われない。
置き換える前の原文を直接読むとエスケープの扱いが変わるため、判定は必ずこのマーカー経由で行う。
md4cの失敗はリンクなしとして扱わず、`TaskFailed` で返す。

md4cのフラグは、tables・strikethrough・tasklistsに、NOHTMLBLOCKSとNOINDENTEDCODEBLOCKSを加える。
プロンプトは節をタグで囲み、地の文をインデントするので、タグとインデントは文として読ませる。

検証は3層に分ける。

- `test/test_markdown.py`：TS版（Bun 1.4.4）が下した63件の判定と102件の候補を、`test/probes/markdown` が再現する。
- `test/test_prompt.py`：TS版のテンプレート試験22件を、`test/probes/prompt` で同じ期待のまま通す。シンボリックリンクを使う事例もここで確かめる。
- `test/cases/check-*.json`：`check` のstdout・stderr・終了コードを、TS版の出力を固定した期待値と照らす。

## 所有権の境界

- JSONの木: `Json` を受け取った側は変更しない。
- fd: 作った関数が呼び出し側へ渡すか、同じ関数の中で閉じる。失敗・キャンセル・正常終了のどれでも、渡さなかったfdは作った側が閉じる。
- 子プロセス: 起動した境界が、結果を返すまでプロセス群の終了を保証する。結果を返した後に残るプロセスはない。
- Cへ渡す領域: `#borrow` で借りるだけで、Cは保持しない。Cが返す値は整数（fd、errno）にとどめ、確保した領域を返さない。
- 状態ファイル: 書き込みは `store` だけが行う。他は読み込みと型への変換を行う。

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

状態の保存先のルート（`$XDG_STATE_HOME/harnexus-crew`）は `environment` が決め、`state_directory` はそのルートを受け取る。

fdはすべてclose-on-execで開く。ロックや一時ファイルのfdが、後から起動する子へ継承されない。

`store` の試験は2種類ある。
単一プロセスの試験は `moon test` が実行する。
競合・強制終了・TS版が書く内容との一致は、`test/probes/store` を複数起動する `test/test_store.py` が確かめる。

## 受入試験

事例を別の一時状態で動かして期待値と照らす仕組みは、[test/README.md](../test/README.md) にある。

## 配置の規約

MoonBitのファイルは、公開する型と定数、入口となる関数、そこから呼ばれる処理、汎用の補助関数、試験の順に置く。
試験は同じパッケージの `*_wbtest.mbt` に置く。
`AGENTS.md`、`.claude/`、`memo/` はローカル資料であり、追跡しない。
