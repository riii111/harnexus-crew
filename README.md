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
- In a T3 Code thread, thread operations go to T3 Code's `t3` CLI instead.

## T3 Code

`launch`, `review`, `state` and `resolve` also work from a T3 Code thread, through T3 Code's `t3` CLI.
Before the first review, add the review home to T3 Code with `t3 project add ~/review-home`.
The reviewer template needs a `reply-T3.md` beside its other replies.
The task skills need T3 Code's thread ID `T3CODE_THREAD_ID` and its thread tools, such as `t3_thread_wait`.
`harnexus-crew check` shows under `t3` whether the reviewer template is ready for T3 Code.

`t3` cannot set a thinking level or change a thread's model, so `--thinking`, and `--model` for a re-review, are refused; change them in T3 Code.
`name`, `watch --link` and `cloud` work only in the Codex App.
`t3` is looked up on `PATH`, then at `~/.t3/bin/t3`; `HARNEXUS_T3_BIN` overrides both.

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
