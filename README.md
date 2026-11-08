# taskctl

My development automation CLI for [harnexus](https://github.com/riii111/harnexus), used with Codex App and Claude Code workers.
Shared as a reference for similar setups; task requests and prompt templates follow my personal workflow.

## Get started

```sh
git clone https://github.com/riii111/taskctl.git
cd taskctl
scripts/install.sh
```

- Installs `taskctl` to `~/.local/bin`; add that directory to `PATH`.
- Use `scripts/install.sh --prefix /absolute/path` for another location.

## Use

Run app commands from a worker or orchestration chat in harnexus.

### Tasks and reviews

Set absolute prompt template paths in `~/.config/harnexus/task.json`: `templates.worker` and `templates.reviewer`.

| Command                                | Purpose                                                             |
| -------------------------------------- | ------------------------------------------------------------------- |
| `taskctl launch --request task.json`   | Start an implementation worker in its own worktree.                 |
| `taskctl review --request review.json` | Request an independent review in the app or from Claude Code Cloud. |
| `taskctl state`                        | Inspect tracked workers and reviews.                                |

- Local reviews: Add `~/review-home` as a project in Codex App.

### Cloud and PR integration

PR monitoring uses [pr-wake](https://github.com/riii111/pr-wake) on `PATH`.

| Command                                  | Purpose                                                 |
| ---------------------------------------- | ------------------------------------------------------- |
| `taskctl cloud --prompt-file request.md` | Start a Claude Cloud session in the app.                |
| `taskctl watch --link <PR URL>`          | Link PR monitoring to the current chat through pr-wake. |

## Troubleshooting

- `taskctl --help`: Command options.
- `taskctl check`: Validate configured prompt templates.
- `taskctl environment`: Identify the current execution environment.
