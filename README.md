# harnexus-crew

My CLI for starting workers, requesting reviews, and monitoring PRs in [harnexus](https://github.com/riii111/harnexus).
Shared as a reference for Codex App and T3 Code setups using my workflow and prompt templates.

## Install

Requires Git, a C compiler, and either Nix or the MoonBit version pinned in [flake.nix](flake.nix).

From this checkout, run:

```sh
scripts/install.sh
```

Installs `harnexus-crew` to `~/.local/bin`.
Add that directory to `PATH`.
Use `scripts/install.sh --prefix /absolute/path` for another location.
The script builds with `moon` on `PATH`, or with the pinned toolchain through `nix develop` when there is none.
If the build or its checks fail, the installed binary stays as it was.

## Use

Run commands from a worker or orchestration chat in harnexus or T3 Code.

Set prompt template paths in `~/.config/harnexus/task.json` (under `$XDG_CONFIG_HOME` when set).
Both `templates.worker` and `templates.reviewer` take absolute paths.
For local reviews, add `~/review-home` as a project in Codex App.
PR monitoring requires [pr-wake](https://github.com/riii111/pr-wake) on `PATH`.

| Command                                        | Purpose                                  |
| ---------------------------------------------- | ---------------------------------------- |
| `harnexus-crew launch --request task.json`     | Start a worker in its own worktree.      |
| `harnexus-crew review --request review.json`   | Request an independent review.           |
| `harnexus-crew state`                          | Inspect tracked workers and reviews.     |
| `harnexus-crew cloud --prompt-file request.md` | Start a Claude Cloud session in the app. |
| `harnexus-crew watch --link <PR URL>`          | Link PR monitoring to the current chat.  |

For new local threads, set `worker` and `reviewer` defaults in `~/.config/harnexus/models.json` (under `$XDG_CONFIG_HOME` when set).
Each role accepts `model` and `thinking` strings. Omitted settings use the built-in defaults, and command-line options take precedence.
The same file can carry `skills` and `clients` objects for other consumers.
Changes apply on the next launch or first review. Re-reviews keep the current settings unless a command-line option changes them.
Run `harnexus-crew check` to validate the model settings and prompt templates.

## T3 Code

`launch`, `review`, `state` and `resolve` also work in T3 Code through its `t3` CLI.
Before the first review, run `t3 project add ~/review-home`.
The reviewer template needs a `reply-T3.md` beside its other replies.
The task skills need `T3CODE_THREAD_ID` and T3 Code's thread tools, such as `t3_thread_wait`.
`harnexus-crew check` reports template readiness under `t3`.

Set thinking levels in T3 Code; `--thinking` is refused.
Change the model for a re-review in T3 Code; `--model` is refused for re-reviews.
PR monitoring in T3 Code needs a pr-wake that supports T3 Code.
`name --pr` keeps the thread's title in T3 Code.
`cloud` works only in the Codex App.
`t3` is found on `PATH` or at `~/.t3/bin/t3`.
Use `HARNEXUS_T3_BIN` to specify another path.

## Troubleshooting

- `harnexus-crew --help`: Command options.
- `harnexus-crew check`: Validate configured prompt templates.
- `harnexus-crew environment`: Identify the current execution environment.
- `unsupported`: Update harnexus and restart the app.
