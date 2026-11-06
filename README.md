# taskctl

Task and review commands for Codex App and Claude Code workers, split out of harnexus.
`taskctl` takes the subcommands, options, JSON output and exit codes of `harnexus-task`, and reads and writes the same state under `$XDG_STATE_HOME/taskctl` and config at `$XDG_CONFIG_HOME/harnexus/task.json`.

## Install

Needs git and the Bun version in `package.json`.

```sh
scripts/install.sh                                  # ~/.local/bin/taskctl from this checkout's HEAD
scripts/install.sh --repo https://github.com/riii111/taskctl --rev <commit> --prefix /opt/bin
scripts/install.sh --compat                         # also link harnexus-task to taskctl
scripts/install.sh --replace-harnexus-task          # same, moving an existing harnexus-task to harnexus-task.pre-taskctl
```

`TASKCTL_PREFIX`, `TASKCTL_REPO` and `TASKCTL_REV` set the same defaults.
The binary is built and checked in a temporary directory first; when that fails, the installed binary stays as it was.
`--compat` refuses to touch a `harnexus-task` that is not already the link, so an existing one is replaced only with `--replace-harnexus-task`.

## What it calls

- App operations go to the harnexus bridge's call socket with call protocol 1. A bridge that does not offer it is reported as `unsupported` before anything is sent; update harnexus and restart the app.
- `watch` runs `pr-wake watch` (found on `PATH`, or at `TASKCTL_PR_WAKE`). The long-running `watch` hands over to the `pr-wake-engine` installed beside it.
- `cloud` asks the bridge's `cloud_open`.
