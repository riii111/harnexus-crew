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
| `cmd/main`        | 入口。現在は未移行を示して失敗するだけ                      | MB05               |

後続の新しいパッケージは、次の名前を目安にする。

| タスク | パッケージ                                     |
| ------ | ---------------------------------------------- |
| MB02   | `os/socket`、`os/process`                      |
| MB03   | `store`（`records`、`run-lock`、ファイル境界） |
| MB04   | `request`、`config`、`environment`             |
| MB06   | `markdown`（md4cのCと同梱ライセンスを含む）    |
| MB07   | `prwake`                                       |
| MB08   | `app`                                          |
| MB09   | `session`                                      |
| MB10   | `cloud`                                        |
| MB11   | `adapter`                                      |

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

## 所有権の境界

- JSONの木: `Json` を受け取った側は変更しない。`Fields::from_json` が複製してから取り出す。
- fd: 作った関数が呼び出し側へ渡すか、同じ関数の中で閉じる。失敗・キャンセル・正常終了のどれでも、渡さなかったfdは作った側が閉じる。
- 子プロセス: 起動した境界が、結果を返すまでプロセス群の終了を保証する。結果を返した後に残るプロセスはない。
- Cへ渡す領域: `#borrow` で借りるだけで、Cは保持しない。Cが返す値は整数（fd、errno）にとどめ、確保した領域を返さない。
- 状態ファイル: 書き込みはMB03の `store` だけが行う。他は読み込みと型への変換を行う。

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
- execの失敗は、通知用のパイプで判別する。execの直前に書き込み側へCLOEXECを付け、EOFなら成功、「段階 errno」が書かれていれば未実行と確定する。締切で止めた後の報告のないEOFは、未実行と断定せず、起動済みの時間切れとして扱う。複数の子を同時に起動するときの書き込み側の継承はMB02で解決する。
- md4cのフラグは、tables・strikethrough・tasklistsに、NOHTMLBLOCKSとNOINDENTEDCODEBLOCKSを加える。原文を直接パースしたときのエスケープ差は、マーカー経路の一致とは別に扱う。
- 試作の性能値（バイナリ約0.6MB、実行時間約2.5ms）は合格値にしない。

## 比較ハーネス

TS版とNative版を別の一時状態で動かして比べる仕組みは、[test/compat/README.md](../test/compat/README.md) にある。

## 配置の規約

MoonBitのファイルは、公開する型と定数、入口となる関数、そこから呼ばれる処理、汎用の補助関数、試験の順に置く。
試験は同じパッケージの `*_wbtest.mbt` に置く。
`AGENTS.md`、`.claude/`、`memo/` はローカル資料であり、追跡しない。
