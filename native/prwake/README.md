# pr-wakeへの委譲と `watch`

PRの監視をpr-wakeへ渡す層。
TS版の `src/task/pr-wake.ts` と `src/task/cli.ts` の `watch` に対応する。
監視の常駐処理、LaunchAgent、pr-wakeの保存状態には触れない。

| 公開する関数・定数                    | TS版                         |
| ------------------------------------- | ---------------------------- |
| `watch(args, env, which~)`            | `watch`                      |
| `call(env, args)`                     | `prWake`                     |
| `is_github_pr(value)`、`NOT_LINKABLE` | `isGitHubPr`、`NOT_LINKABLE` |

`call` は後続の `name`（MB09）が `["link", pr, "--take-over"]` で使う。
返す値は、pr-wakeが標準出力に書いたJSONオブジェクトで、メンバーの順序を保つ。
PATH上のコマンド探索 `which` は呼び出し側が注入する（`cli/registry.mbt` が `which.in_env(env)` を渡す）。

## 契約

- pr-wakeは `HARNEXUS_CREW_PR_WAKE`（絶対パス）、未設定または空ならPATH上の `pr-wake`。相対パスは何も起動せずに拒否する。
- `call` は `pr-wake watch <args>` を子の環境にこのプロセスの環境をそのまま渡して実行する。締切は `dry-run` が10分、ほかは1分。
- 終了コードが0以外なら、標準エラーを `trim` して失敗に添える。0でも、標準出力が1つのJSONオブジェクトでなければ失敗にする。
- 起動できない・締切・出力超えの失敗には、インストールまたは `HARNEXUS_CREW_PR_WAKE` の指定を促す文を付ける。
- `watch` の各オプションは、`--release PR` → `release`、`--status` → `status --json`、`--sender` → `sender`、`--link PR` → `link`、`--dry-run [--pr PR]...` → `dry-run`。`--link` は github.com のPRのURLだけを受け付け、pr-wakeを呼ぶ前に拒否する。
- オプションなしの `watch` は、pr-wakeの実体の隣にある `pr-wake-engine watch` を、このプロセスの標準入出力のまま実行して終了コードを待つ。実体はリンクをたどった先で探す。0なら `{"watch":"stopped"}`、それ以外は終了コードを添えて失敗にする。
- Cloudでは `watch` を何も起動せずに拒否する。

## 試験

`moon test` の `prwake` は、`test/native/mocks/pr-wake.sh`（pr-wakeとエンジンの代役）を実際の子プロセスとして動かす。
代役は引数と環境を記録し、計画した出力・終了コード・待ちを返す。
締切の試験は、`call` の内側の関数に短い締切を渡す。

CLI全体の比較は `test/compat/cases/watch-*.json`（TS版との比較）で行う。
