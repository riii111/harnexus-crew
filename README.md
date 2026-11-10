# harnexus-crew

My CLI for starting workers, requesting reviews, and monitoring PRs in [harnexus](https://github.com/riii111/harnexus).
Shared as a reference for Codex App and Claude Code setups using my workflow and prompt templates.

## Install

Requires Git and the Bun version specified in [package.json](package.json).

From this checkout, run:

```sh
scripts/install.sh
```

Installs `harnexus-crew` to `~/.local/bin`.
Add that directory to `PATH`.
Use `scripts/install.sh --prefix /absolute/path` for another location.

## Use

Run app commands from a worker or orchestration chat in harnexus.

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

## Troubleshooting

- `harnexus-crew --help`: Command options.
- `harnexus-crew check`: Validate configured prompt templates.
- `harnexus-crew environment`: Identify the current execution environment.
- `unsupported`: Update harnexus and restart the app.
