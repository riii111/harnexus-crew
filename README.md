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
The binary is built in a temporary directory and must start and fill the worker and reviewer templates that `task.json` names (`taskctl check`) before it replaces anything; when a step fails, the installed `taskctl` and `harnexus-task` stay as they were.
`--compat` refuses to touch a `harnexus-task` that is not already the link, so an existing one is replaced only with `--replace-harnexus-task`.

## What it calls

- App operations go to the harnexus bridge's call socket with call protocol 1. A bridge that does not offer it is reported as `unsupported` before anything is sent; update harnexus and restart the app.
- `watch` runs `pr-wake watch` (found on `PATH`, or at `TASKCTL_PR_WAKE`). The long-running `watch` hands over to the `pr-wake-engine` installed beside it.
- `cloud` asks the bridge's `cloud_open`.

## Cloud review chats in harnexus

Register `taskctl adapter serve --id taskctl` as harnexus's `externalConversationAdapter`, with `command` set to the absolute path of `taskctl` and `args` to `["adapter", "serve", "--id", "taskctl"]`.

- `observe` records the reviews Cloud sessions print in `$XDG_STATE_HOME/taskctl/cloud-observe/journal.jsonl` and writes nothing else, while harnexus keeps showing reviews itself.
- `write` shows each review once in its reviewer's chat, in the same `cloud-reviews` folder harnexus used, and passes a message written in that chat to the Cloud session that ran the reviewer.

To switch from `observe` to `write`, stop the app, run `taskctl adapter handover` to queue the recorded reviews that harnexus did not send, then set `mode` to `write` and start the app.
`taskctl adapter export-links` prints the chats `harnexus-task cloud` opened as `{"version":1,"links":[{"sessionId","threadId","reservedAt"}]}`, the form `harnexus state import-cloud-links` reads; a `threadId` of `null` is a chat whose opening never reported back, which is never opened again.
`taskctl adapter import-links FILE` writes such a file, as `harnexus state export-cloud-links` prints it, back to `harnexus-task cloud`'s records without replacing a chat already recorded. To go back to a harnexus from before the split, run it before starting that version.
