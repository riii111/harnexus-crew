# taskctl

My development automation CLI for [harnexus](https://github.com/riii111/harnexus), used with Codex App and Claude Code workers.
Shared as a reference for similar setups; task requests and prompt templates follow my personal workflow.

## Get started

- Git and Bun 1.4.4.
- A running harnexus-enabled Codex App for chat operations.
- Worker and reviewer prompt templates: absolute paths in `templates.worker` and `templates.reviewer` in `~/.config/harnexus/task.json` (`$XDG_CONFIG_HOME` is respected).
- For local reviews, add `~/review-home` as a project in Codex App.
- For PR monitoring, install [pr-wake](https://github.com/riii111/pr-wake) on `PATH`.

```sh
git clone https://github.com/riii111/taskctl.git
cd taskctl
scripts/install.sh
```

- Installs `taskctl` to `~/.local/bin`; add that directory to `PATH`.
- Use `scripts/install.sh --prefix /absolute/path` for another location.

## Use

Run chat commands from a worker or orchestration chat.

| Command                                  | Purpose                                                             |
| ---------------------------------------- | ------------------------------------------------------------------- |
| `taskctl launch --request task.json`     | Start an implementation worker in its own worktree.                 |
| `taskctl review --request review.json`   | Request an independent review in the app or from Claude Code Cloud. |
| `taskctl state`                          | Inspect tracked workers and reviews.                                |
| `taskctl watch --link <PR URL>`          | Link PR monitoring to the current chat through pr-wake.             |
| `taskctl cloud --prompt-file request.md` | Start a Claude Cloud session in the app.                            |

- `taskctl --help`: Command options.
- `taskctl check`: Validate configured prompt templates.
- `taskctl environment`: Identify the current execution environment.
