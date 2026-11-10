import { join } from "node:path";

import { Result } from "better-result";

import { type CallOutcome, callApp } from "../app/call.ts";
import { projectsIn } from "../app/projects.ts";
import { callT3, t3Home } from "../app/t3.ts";
import { realPathOrSelf } from "../lib/fs.boundary.ts";
import { type Fields, isObject } from "../lib/object.ts";
import { fail, type TaskFailed } from "./format.ts";
import { chatId, codexHome, type Env, homeOf, NAME } from "./request.ts";

export type App = "codex" | "t3";

export const T3_THREAD_ENV = "T3CODE_THREAD_ID";

export type AppCall = (
  caller: string,
  tool: string,
  args: Fields,
) => Promise<Fields>;

// What differs between the apps a worker and its reviewer run in; everything else a task does is the same in both.
export type Host = {
  // The variable naming the thread a command runs in.
  threadVariable: string;
  call: AppCall;
  // The project a reviewer is started in, as the app's create_thread target names it.
  reviewProject: (caller: string) => Promise<Result<string, TaskFailed>>;
  // The folder whose <id>/<name> folders are worker worktrees.
  worktrees: string;
  // The thinking a worker and a reviewer get when none is asked for, or null when the app cannot be told one.
  thinking: { worker: string; reviewer: string } | null;
  // Which reply template a reviewer follows to hand its result to the worker.
  replyTo: (workerAI: string) => string;
};

type HostDeps = { env: Env; which: (name: string) => string | null };

export const hostOf = (deps: HostDeps): Host =>
  appOf(deps.env) === "t3" ? t3Host(deps) : codexHost(deps.env);

export const callerId = (env: Env) => {
  const variable = appOf(env) === "t3" ? T3_THREAD_ENV : CODEX_THREAD_ENV;
  const value = env[variable];
  if (value === undefined || value === "")
    return fail(`${variable} is not set; run ${NAME} from a thread`);
  return chatId(value, variable);
};

// Refuses in T3 Code a command that only the Codex App can carry out for the thread it runs in.
export const refuseInT3 = (
  env: Env,
  command: string,
  alternative: string,
): Result<void, TaskFailed> =>
  appOf(env) === "t3"
    ? fail(
        `${command} needs the Codex App and is unavailable in T3 Code. ${alternative}`,
      )
    : Result.ok();

export const appOf = (env: Env): App => {
  // T3 Code sets its thread for every agent and job it starts, and runs Codex there with a CODEX_THREAD_ID of Codex's own, so its variable decides first.
  const t3 = env[T3_THREAD_ENV];
  return t3 !== undefined && t3 !== "" ? "t3" : "codex";
};

const CODEX_THREAD_ENV = "CODEX_THREAD_ID";

const codexHost = (env: Env): Host => {
  const call: AppCall = (caller, tool, args) =>
    callApp({ env, home: homeOf(env) }, caller, tool, args);
  return {
    threadVariable: CODEX_THREAD_ENV,
    call,
    reviewProject: async (caller) => {
      const home = await reviewHome(env);
      const answer = await call(caller, "list_projects", {});
      if (answer.outcome !== ("done" satisfies CallOutcome))
        return fail(`list_projects failed: ${JSON.stringify(answer)}`);
      for (const project of projectsIn(answer.result)) {
        if (!isObject(project)) continue;
        const { path, projectId } = project;
        if (typeof path !== "string" || typeof projectId !== "string") continue;
        if ((await realPathOrSelf(path)) === home) return Result.ok(projectId);
      }

      return fail(
        `add ${home} to the Codex app as a project, so reviewers run there instead of in a worktree of their own`,
      );
    },
    worktrees: join(codexHome(env), "worktrees"),
    thinking: { worker: "high", reviewer: "medium" },
    replyTo: (workerAI) => workerAI,
  };
};

const t3Host = ({ env, which }: HostDeps): Host => {
  const home = homeOf(env);
  return {
    threadVariable: T3_THREAD_ENV,
    call: (_caller, tool, args) => callT3({ env, home, which }, tool, args),
    // The t3 CLI takes a folder for its project, and says so when no project holds it.
    reviewProject: async () => Result.ok(await reviewHome(env)),
    // T3 Code keeps a worktree at <repository name>/<branch> under its own folder.
    worktrees: join(t3Home(env, home), "worktrees"),
    thinking: null,
    // A reviewer in T3 Code answers through T3 Code's own thread tools, whichever AI the worker is.
    replyTo: () => "T3",
  };
};

const reviewHome = (env: Env) =>
  // A reviewer reads the worker's checkout by its path, so it runs in an empty project rather than a worktree of its own that counts toward the app's worktree limit.
  realPathOrSelf(join(homeOf(env), "review-home"));
