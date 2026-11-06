# S1 移行基準（harnexus 分離）

基点 commit: harnexus 8127612、pr-wake 07b9c3d、dotfiles 7837c28（計画の調査基点 eca9ea5 から main は進んでいる。差分は S5 着手時に確認する）。
taskctl は public。Cloud から認証なしで clone できる（S1 で確認済み）。
切り戻し用の旧 CLI は harnexus 8127612 の `scripts/install-cloud-task.sh` から取得する。

## 移す対象と、残る本体からの依存

本体から移転対象への import は次の5本だけ。S2 でこれらを解消する。

1. `src/cli/bridge.ts:7`：`codexHome`（task/request.ts）。共通設定へ移す。
2. `src/cli/bridge-wiring.ts:4`：`createCloudReviews`（cloud/review-chats.ts）。外部会話接続へ置き換える。
3. `src/features/conversation/claude/cloud/runtime.ts:27`：`reviewsIn`/`CloudReview`（cloud/reviews.ts）。runtime と review-chats は相互に依存している。
4. `src/cli/check-bun.ts:3`：`unpinnedBun`（task/bun-pin.ts）。taskctl へ移す。
5. `src/cli/task.ts`：task のエントリ。taskctl へ移す。

逆方向（task から本体）の依存は次のとおり。移転先へ写すか、公開 IPC 経由に変える。

- `features/link`：call-gateway の `CallOutcome`、delegations。
- `infra/claude/cloud*`：`startCloudSession`、`parseCloudSessionId`。cloud 操作は本体の `harnexus cloud` へ。
- `infra/codex/projects`
- `lib/*`：config、socket、args、fs、json、process、run。

依存規則は `test/dependency-rules.test.ts:269-300` にある。`test/function-comments.test.ts:98` が prwatch/store.ts を名指ししている。

runtime.ts の特別扱いは次のとおり。

- `CLOUD_SKILL`/`cloudSkillCommandOf`（:1465-1470, :324-332）
- `/cloud-review`（:1475, :294-316）
- `reviewerAsk`（:1484）
- `noticeReviews`（:973-998）
- `child-chats.ts:33-37` の「Impl｜」解析

## 旧 CLI の仕様（harnexus-task、src/features/task/cli.ts）

終了コードは成功 0（stdout に JSON 1行）、実行時エラー 1（stderr に `harnexus-task: <msg>`）、使い方エラー 2。

| サブコマンド | 主な引数                                                                    | 出力キー                                                                                                                                                       |
| ------------ | --------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| launch       | `--request [--model claude-sonnet-5-5 --thinking high]`                     | `{existing,state}` または `{tool,threadId,model,effort,expected,state}`                                                                                        |
| review       | `--request [--model --thinking --update-base --recover discard --ask FILE]` | App: launch と同じ。Cloud: `{status,verdict,taskId,base,head,reviewer,answer,state}`。ask: `{status,kind:"reply",askedAt,verdict,taskId,head,reviewer,answer}` |
| state        | `[--request]`                                                               | 一覧 `{path:json}`、または `{kind,…,requested,actual,pending,pendingThreadId,statePath,prompt,refusedThreadIds}`                                               |
| resolve      | `--request (--sent [--thread-id]\|--not-sent)`                              | `{released,status}`、または confirm の結果                                                                                                                     |
| name         | `--pr PR`                                                                   | `{threadId,title,watched,renameError?,warning?}`                                                                                                               |
| watch        | `[--dry-run [--pr]…\|--release PR\|--status\|--sender\|--link PR]`          | 常駐時は JSON ログ。`--status`: `{sender\|senderError,prs:[{pr,worker,status,reason,pending,followUp,awaitingAnswer,handingOver,checkedAt}]}`                  |
| environment  | なし                                                                        | `{environment,source,host?,note}`                                                                                                                              |
| cloud        | `(--link\|--prompt-file) [--project --title --model --thinking]`            | `{threadId,cloudSessionId,url,alreadyLinked?}`                                                                                                                 |

## call socket（v0）

1行の JSON を送り、1行の応答を受けて閉じる。

- 要求: `{threadId,tool,arguments}`。空行は接続確認。
- 操作: list_projects、create_thread、send_message_to_thread、read_thread、wait_threads、name_thread、cloud_chat。
- 応答の outcome: done、tool_error、model_mismatch、first_turn_refused、unknown、not_sent、rejected、invalid。
- `call.ts` の終了コード: 0 done、1 tool_error、2 not_sent、3 unknown、4 rejected、5 invalid、6 model_mismatch、7 first_turn_refused。
- 未送信と結果不明の区別: 接続前の失敗は not_sent、接続後の失敗は unknown。

## 状態と設定のパス（維持する）

- 設定: `$XDG_CONFIG_HOME|~/.config` 配下の `/harnexus/task.json` と `pr-watch.json`。
- タスクの状態: `$XDG_STATE_HOME|~/.local/state` 配下の `/taskctl/`。
  - `{launch,review,cloud-review}/<sha256(key)[:16]>/{state,pending,history,lock}.json`
  - `watch/<sha256(repo#n)>/{link,state}.json`、`watch/sender.json`、`watch/watch.lock`
  - `cloud-chats/<session>.json`
- 本体の状態: `HARNEXUS_STATE_PATH`（既定は `~/.local/state/harnexus/threads.json`）と同じディレクトリに `call.sock`、`cloud-copies/`、`cloud-reviews/` がある。cloud-reviews の中身は `chats.json`、`<key>.json`、`<key>.reserved`、`asked-*.json`。
- 環境変数:
  - `HARNEXUS_CALL_SOCKET`、`HARNEXUS_EXECUTION_ENV`、`CODEX_HOME`
  - `HARNEXUS_CODEX_BIN`、`HARNEXUS_REVIEW_TIMEOUT_MS`、`HARNEXUS_REVIEW_KILL_GRACE_MS`
  - `CODEX_THREAD_ID`、`CLAUDE_CODE_SESSION_ID`、`CLAUDE_CODE_REMOTE`

Bun のバージョン指定 1.4.4 は、package.json の packageManager、flake.nix、ci.yml にある。

## pr-wake との接点

- `internal/watch/watch.go`: LaunchAgent `io.github.riii111.pr-wake.watch` が `~/.local/bin/harnexus-task watch` を起動する（:61-69）。
  - install の前に `pr-watch.json` があるかを確認し、`watch --dry-run` を実行する（:76-99）。
  - status は `watch --status` の JSON を整形する（:101-165）。
- `review` サブコマンド（`internal/review/*`）は変更しない。
- CI はない。検証は `go test ./...` で行う。

## dotfiles との接点

- `scripts/cloud-setup.sh`
  - :29-30 `HARNEXUS_REPO` と `HARNEXUS_TASK_PREFIX`。
  - :68-75 `~/.cache/cloud-setup/options` への保存。
  - :91 skill の配置。
  - :96-105 task.json の書き出し。
  - :107-125 `HARNEXUS_TASK=1` のとき、ls-remote で取得した commit を比べて再ビルドする。
- `scripts/cloud-setup/refresh.sh`：options を読み直してから再実行する。
- テスト：`tests/test_cloud_setup.py`（:89-129, :205-247, :300-349）。
- 許可設定
  - `dot_codex/rules/default.rules.tmpl:59-73`
  - `dot_claude/settings.json.tmpl:78-85,284-291`
  - 許可されている8種: launch、review、state、name、cloud、`watch --link`、`watch --sender`、`watch --status`。
  - skill は `environment` と `resolve` も使うが、許可ルールにない。
- skill から呼ばれるコマンド
  - task-session-launch、task-review-cycle、task-worker、task-orchestration、pr-watch-link、task-dispatch：harnexus-task。
  - cloud-session：`harnexus-task cloud`。
  - work-retro：harnexus の checkout パス。
- CI は `main-verify.yml`（ai-docs と macos の `dotctl test`）。PR のマージには承認1件が必要。

## 基準ケース（受入で使う）

- 本体単独：taskctl、pr-wake、個人 SKILL、task.json がない状態で、bridge の起動、Claude との会話、承認、停止、再開、Cloud 連携、`HARNEXUS_CALL_SOCKET=off` を確かめる。
- 個人運用：旧状態のコピーに対して、launch と review の継続、同じ reviewer への ask、watch の status、link、sender、既読と保留を確かめる。
- Mac 実機でしか確かめられないもの（App、LaunchAgent、切替と切り戻しの往復）は S6 で行う。Cloud では成功扱いにしない。
