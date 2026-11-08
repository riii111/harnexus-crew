import { dirname, isAbsolute, join } from "node:path";

import { Result } from "better-result";

import { realPathOrSelf } from "../lib/fs.boundary.ts";
import { parseJson } from "../lib/json.boundary.ts";
import { type Fields, isObject } from "../lib/object.ts";
import type { CommandFailed, CommandOutput } from "../lib/process.boundary.ts";
import { fail, type TaskFailed } from "./format.ts";
import type { Env } from "./request.ts";

export type ToolRunner = (
  argv: readonly string[],
  env: Env,
  timeoutMs: number,
) => Promise<Result<CommandOutput, CommandFailed>>;

const PR_WAKE_ENV = "HARNEXUS_CREW_PR_WAKE";
const ENGINE = "pr-wake-engine";
// A dry run reads every configured PR from GitHub, so it is given as long as a person waits for it.
const DRY_RUN_TIMEOUT_MS = 10 * 60_000;
const CALL_TIMEOUT_MS = 60_000;

// The pr-wake command, found on PATH unless an absolute path is set, so the watch is owned and updated by pr-wake alone.
export const prWakeCommand = (env: Env) => {
  const variable =
    env[PR_WAKE_ENV] === undefined ? "TASKCTL_PR_WAKE" : PR_WAKE_ENV;
  const set = env[variable];
  if (set === undefined || set === "") return Result.ok("pr-wake");
  return isAbsolute(set)
    ? Result.ok(set)
    : fail(`${variable} must be an absolute path`);
};

export const NOT_LINKABLE =
  "the PR watch needs the URL https://github.com/<owner>/<repo>/pull/<number>";

// The watch reaches GitHub only, so a PR on another host is named but never linked.
const GITHUB_PR =
  /^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[1-9][0-9]*(?:[/?#]\S*)?$/;

export const isGitHubPr = (value: string) => GITHUB_PR.test(value);

// Runs one pr-wake watch subcommand and reads the one JSON object it prints, as harnexus-task watch printed it.
export const prWake = (
  run: ToolRunner,
  env: Env,
  args: readonly string[],
): Promise<Result<Fields, TaskFailed>> =>
  Result.gen(async function* () {
    const command = yield* prWakeCommand(env);
    const timeout =
      args[0] === "dry-run" ? DRY_RUN_TIMEOUT_MS : CALL_TIMEOUT_MS;
    const ran = await run([command, "watch", ...args], env, timeout);
    if (ran.isErr())
      return fail(
        `${ran.error.message}; install pr-wake, or set ${PR_WAKE_ENV} to its absolute path`,
      );
    const { status, stdout, stderr } = ran.value;
    const said = stderr.trim();
    if (status !== 0)
      return fail(
        `pr-wake watch ${args.join(" ")} failed with exit ${status}${said === "" ? "" : `: ${said}`}`,
      );
    const parsed = parseJson(stdout.trim()).unwrapOr(null);
    return isObject(parsed)
      ? Result.ok(parsed)
      : fail(`pr-wake watch ${args.join(" ")} printed no JSON object`);
  });

// The engine pr-wake installs beside itself, which its LaunchAgent runs; the long-running watch is handed to it.
export const prWakeEngine = (
  env: Env,
  which: (name: string) => string | null,
) =>
  Result.gen(async function* () {
    const command = yield* prWakeCommand(env);
    const found = isAbsolute(command) ? command : which(command);
    if (found === null)
      return fail(
        `pr-wake is not on PATH; install pr-wake, or set ${PR_WAKE_ENV} to its absolute path`,
      );
    return Result.ok(join(dirname(await realPathOrSelf(found)), ENGINE));
  });
