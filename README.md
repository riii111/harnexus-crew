# harnexus-crew

Task and review commands for Codex and Claude Code workers in the Codex App or T3 Code, split out of harnexus.
State is kept under `$XDG_STATE_HOME/harnexus-crew` and config at `$XDG_CONFIG_HOME/harnexus/task.json`.

## Install

Needs git and the Bun version in `package.json`.

```sh
scripts/install.sh                                  # ~/.local/bin/harnexus-crew from this checkout's HEAD
scripts/install.sh --repo https://github.com/riii111/taskctl --rev <commit> --prefix /opt/bin
```

`HARNEXUS_CREW_PREFIX`, `HARNEXUS_CREW_REPO` and `HARNEXUS_CREW_REV` set the same defaults.
The binary is built in a temporary directory and must start and fill the worker and reviewer templates that `task.json` names (`harnexus-crew check`) before it replaces anything; when a step fails, the installed `harnexus-crew` stays as it was.

## What it calls

- App operations go to the harnexus bridge's call socket with call protocol 1. A bridge that does not offer it is reported as `unsupported` before anything is sent; update harnexus and restart the app.
- `watch` runs `pr-wake watch` (found on `PATH`, or at `HARNEXUS_CREW_PR_WAKE`). The long-running `watch` hands over to the `pr-wake-engine` installed beside it.
- `cloud` asks the bridge's `cloud_open`.
- In a T3 Code thread, thread operations go to T3 Code's `t3` CLI instead; see below.

## T3 Code

A command run in a T3 Code thread, which T3 Code marks with `T3CODE_THREAD_ID`, starts and messages threads with `t3 thread start` and `t3 thread send`.

- `launch` starts the worker in a new T3 Code worktree based on `startingBranch`, or the project's `HEAD` without one; `projectId` is the T3 Code project's ID.
- `review` takes a checkout in `$T3CODE_HOME/worktrees` (by default `~/.t3/worktrees`) and starts the reviewer in `~/review-home`, which must be a T3 Code project: `t3 project add ~/review-home`.
- The reviewer template's `reply-{reply_to}.md` link resolves to `reply-T3.md`, so the reviewer answers with T3 Code's `t3_thread_send`; a Claude worker waits with `t3_thread_wait` and `t3_thread_read`. `harnexus-crew check` reports under `t3` whether the template can be filled for T3 Code without failing for it, and a review in T3 Code sends nothing until it can.
- `--thinking`, and `--model` for a re-review, are refused, since `t3` cannot set them; set them in T3 Code.
- `name`, `watch --link` and `cloud` need the Codex App.
- `t3` is taken from `HARNEXUS_T3_BIN`, then `PATH`, then `~/.t3/bin/t3`, the desktop app's launcher, and must run outside the sandbox.

## Cloud review chats in harnexus

Register `harnexus-crew adapter serve --id harnexus-crew` as harnexus's `externalConversationAdapter`, with `command` set to the absolute path of `harnexus-crew` and `args` to `["adapter", "serve", "--id", "harnexus-crew"]`.

- `observe` records the reviews Cloud sessions print in `$XDG_STATE_HOME/harnexus-crew/cloud-observe/journal.jsonl` and writes nothing else, while harnexus keeps showing reviews itself.
- `write` shows each review once in its reviewer's chat, in the same `cloud-reviews` folder harnexus used, and passes a message written in that chat to the Cloud session that ran the reviewer.

To switch from `observe` to `write`, stop the app, run `harnexus-crew adapter handover` to queue the recorded reviews that harnexus did not send, then set `mode` to `write` and start the app.
`harnexus-crew adapter export-links` prints the chats `harnexus-crew cloud` opened as `{"version":1,"links":[{"sessionId","threadId","reservedAt"}]}`, the form `harnexus state import-cloud-links` reads; a `threadId` of `null` is a chat whose opening never reported back, which is never opened again.
`harnexus-crew adapter import-links FILE` writes such a file, as `harnexus state export-cloud-links` prints it, to `harnexus-crew cloud`'s records without replacing a chat already recorded.

## Dependency security

`minimatch` is temporarily overridden to 11.0.5 for
[GHSA-g3hv-75wg-m249](https://github.com/advisories/GHSA-g3hv-75wg-m249).
The affected 10.x copy comes from ESLint, installed as a peer of the stylistic
lint plugin; it is not a harnexus-crew runtime dependency. ESLint and
`@eslint/config-array` still require 10.x, so the override crosses their declared
major range. Their used `Minimatch` constructor and `match` APIs remain supported;
`test/lint-dependencies.test.ts` checks glob traversal, ignores and rule enforcement.
Remove the override once those upstream dependencies accept a fixed version and
`bun audit` plus the lint compatibility test pass without it.
