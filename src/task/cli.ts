import { Result, TaggedError } from "better-result";

import { type CallOutcome, UNSENT } from "../app/call.ts";
import { type OptionTypes, parseOptions } from "../lib/args.boundary.ts";
import { readRegularTextFile } from "../lib/fs.boundary.ts";
import { type Fields, isObject } from "../lib/object.ts";
import { runCommand, runInherited } from "../lib/process.boundary.ts";
import { cloudReview } from "./cloud-review.ts";
import {
  declaredEnvironment,
  detectEnvironment,
  refuseInCloud,
} from "./environment.ts";
import { asText, fail, isBlank, jsonEqual, truthy } from "./format.ts";
import {
  isGitHubPr,
  NOT_LINKABLE,
  prWake,
  prWakeEngine,
  type ToolRunner,
} from "./pr-wake.ts";
import { type SaveJson, saveJson } from "./records.ts";
import {
  callerId,
  candidate,
  chatId,
  type Env,
  type GitRunner,
  gitIn,
  io,
  launchRequest,
  NAME,
  readJson,
  reviewFields,
  reviewRequest,
  sessionValue,
  singleLine,
  workerFields,
} from "./request.ts";
import {
  callApp,
  launchOfThread,
  launchSession,
  listState,
  reviewProject,
  reviewSession,
} from "./session.ts";
import { taskPrompt } from "./templates.ts";

export type TaskDeps = {
  env: Env;
  runGit: GitRunner;
  saveJson: SaveJson;
  // Runs pr-wake, which owns the PR watch and its records.
  runTool: ToolRunner;
  // Hands the long-running watch to pr-wake's engine and returns its exit status.
  runWatch: (
    engine: string,
    env: Env,
  ) => Promise<Result<number, { message: string }>>;
  which: (name: string) => string | null;
  // The folder the command runs in, whose project is used when none is named; the process's own when absent.
  cwd?: string;
  // The name the command was run by, taskctl or the harnexus-task it replaces, which its messages start with.
  name?: string;
};

export const TASK_DEPS = {
  runGit: (argv, env) => runCommand(argv[0] ?? "git", argv.slice(1), env),
  saveJson,
  runTool: (argv, env, timeoutMs) =>
    runCommand(argv[0] ?? "pr-wake", argv.slice(1), env, timeoutMs),
  runWatch: (engine, env) => runInherited(engine, ["watch"], env),
  which: (name) => Bun.which(name),
} satisfies Omit<TaskDeps, "env">;

type LaunchArgs = {
  request: string;
  model: string | undefined;
  thinking: string | undefined;
};

type ReviewArgs = LaunchArgs & {
  updateBase: boolean;
  recover: "discard" | undefined;
  // A message for the task's reviewer, in a Claude Code cloud session.
  ask: string | undefined;
};

type StateArgs = { request: string | undefined };

type ResolveArgs = {
  request: string;
  sent: boolean;
  threadId: string | undefined;
};

type NameArgs = { pr: string };

type WatchArgs = {
  dryRun: boolean;
  prs: string[];
  release: string | undefined;
  status: boolean;
  sender: boolean;
  link: string | undefined;
};

type CloudArgs = {
  link: string | undefined;
  promptFile: string | undefined;
  project: string | undefined;
  title: string | undefined;
  model: string | undefined;
  thinking: string | undefined;
};

const worktreeTarget = (project: unknown) => ({
  type: "project",
  projectId: project,
  environment: { type: "worktree" } as Fields,
});

const threadTitle = (kind: string, data: Fields) =>
  truthy(data.displayName)
    ? `${kind}｜${asText(data.displayName)}`
    : `${kind} ${asText(data.taskId)}`;

const withoutName = ({ displayName: _, ...rest }: Fields) => rest;

const sameTask = (recorded: unknown, data: Fields) =>
  // The name is only shown, so renaming a task still finds its worker.
  isObject(recorded) && jsonEqual(withoutName(recorded), withoutName(data));

const launch = (args: LaunchArgs, deps: TaskDeps) =>
  Result.gen(async function* () {
    yield* refuseInCloud(deps.env, "launch");
    const data = yield* Result.await(launchRequest(args.request));
    const session = yield* Result.await(launchSession(data, deps));
    if (session.state !== null) {
      if (!sameTask(session.state.request, data))
        return fail(
          `${asText(data.taskId)} already has worker ${asText(session.state.threadId)} ` +
            "launched with a different request",
        );
      return Result.ok<Fields>({
        existing: session.state.threadId ?? null,
        state: session.statePath,
      });
    }

    const target = worktreeTarget(data.projectId);
    const fields = yield* Result.await(workerFields(data));
    const prompt = yield* Result.await(taskPrompt(deps.env, "worker", fields));
    const sent: Fields = {
      prompt,
      target,
      title: threadTitle("Impl", data),
      model: args.model || "claude-sonnet-5-5",
      thinking: args.thinking || "high",
    };
    if (truthy(data.startingBranch))
      target.environment.startingState = {
        type: "branch",
        branchName: data.startingBranch,
      };
    const caller = yield* callerId(deps.env);
    return await session.send(caller, "create_thread", sent, {
      request: data,
      workspace: target,
    });
  });

const review = (args: ReviewArgs, deps: TaskDeps) =>
  Result.gen(async function* () {
    const declared = yield* declaredEnvironment(deps.env);
    if (declared?.environment === "cloud" && declared.host === "claude")
      return await cloudReview(
        {
          request: args.request,
          updateBase: args.updateBase,
          ...(args.model === undefined ? {} : { model: args.model }),
          ...(args.thinking === undefined ? {} : { thinking: args.thinking }),
          ...(args.recover === undefined ? {} : { recover: args.recover }),
          ...(args.ask === undefined ? {} : { ask: args.ask }),
        },
        {
          env: deps.env,
          saveJson: deps.saveJson,
          git: gitIn(deps.runGit, deps.env),
        },
      );
    yield* refuseInCloud(deps.env, "review");
    // In the app the reviewer is a chat of its own, which is asked there.
    if (args.ask !== undefined)
      return fail(
        "--ask applies to review only in a Claude Code cloud session",
      );
    if (args.recover !== undefined)
      return fail(
        "--recover applies to review only in a Claude Code cloud session",
      );
    const git = gitIn(deps.runGit, deps.env);
    let data = yield* Result.await(reviewRequest(args.request, deps.env, git));
    const worker = yield* callerId(deps.env);
    if (!Object.hasOwn(data, "workerChatId")) data.workerChatId = worker;
    if (data.workerChatId !== worker)
      return fail("workerChatId in the request must equal CODEX_THREAD_ID");
    const session = yield* Result.await(reviewSession(data, deps));
    yield* session.checkIdle();
    const recorded = session.state?.candidate ?? null;
    if (truthy(recorded) && !isObject(recorded))
      return fail(`${session.statePath} holds an invalid candidate`);
    const previous = isObject(recorded) && truthy(recorded) ? recorded : null;
    data = yield* Result.await(candidate(data, previous, args.updateBase, git));
    if (previous !== null) {
      for (const key of [
        "taskId",
        "workerAI",
        "workerChatId",
        "projectId",
        "checkout",
      ]) {
        const before = await sessionValue(previous, key);
        if (!jsonEqual(before, await sessionValue(data, key)))
          return fail(`review session must keep the original ${key}`);
      }

      if (jsonEqual(previous.head ?? null, data.head))
        return fail(
          `head ${asText(data.head)} was already sent to reviewer ` +
            `${asText(session.state?.reviewer)}; wait for its result`,
        );
    }

    const fields = yield* Result.await(reviewFields(data));
    const sent: Fields = {
      prompt: yield* Result.await(taskPrompt(deps.env, "reviewer", fields)),
    };
    let tool = "create_thread";
    if (session.state !== null) {
      tool = "send_message_to_thread";
      sent.threadId = session.state.reviewer;
      if (args.model !== undefined) sent.model = args.model;
      if (args.thinking !== undefined) sent.thinking = args.thinking;
    } else {
      const project = yield* Result.await(
        reviewProject(deps.env, String(data.workerChatId)),
      );
      Object.assign(sent, {
        target: {
          type: "project",
          projectId: project,
          environment: { type: "local" },
        },
        title: threadTitle("Review", data),
        model: args.model || "gpt-6.1-sol",
        thinking: args.thinking || "medium",
      });
    }

    return await session.send(String(data.workerChatId), tool, sent, {
      candidate: data,
      workspace: data.checkout,
    });
  });

const requestedSession = (path: string, deps: TaskDeps) =>
  Result.gen(async function* () {
    const raw = yield* Result.await(readJson(path));
    if (isObject(raw) && Object.hasOwn(raw, "completionTarget")) {
      const data = yield* Result.await(launchRequest(path));
      return await launchSession(data, deps);
    }

    const git = gitIn(deps.runGit, deps.env);
    const data = yield* Result.await(reviewRequest(path, deps.env, git));
    data.workerChatId = yield* callerId(deps.env);
    return await reviewSession(data, deps);
  });

const state = (args: StateArgs, deps: TaskDeps) =>
  Result.gen(async function* () {
    if (args.request === undefined) return await listState(deps.env);
    yield* refuseInCloud(deps.env, "state --request");
    const session = yield* Result.await(requestedSession(args.request, deps));
    return await session.show();
  });

const resolve = (args: ResolveArgs, deps: TaskDeps) =>
  Result.gen(async function* () {
    yield* refuseInCloud(deps.env, "resolve");
    const thread = args.threadId
      ? yield* chatId(args.threadId, "--thread-id")
      : null;
    const session = yield* Result.await(requestedSession(args.request, deps));
    return await session.resolve(args.sent, thread);
  });

// A PR URL may carry a tab, query or fragment after its number, as when copied from the browser.
const PR_NUMBER =
  /^(?:#?([1-9][0-9]*)|https:\/\/\S+\/pull\/([1-9][0-9]*)(?:[/?#]\S*)?)$/;

const name = (args: NameArgs, deps: TaskDeps) =>
  Result.gen(async function* () {
    yield* refuseInCloud(deps.env, "name");
    const matched = PR_NUMBER.exec(args.pr);
    const number = matched?.[1] ?? matched?.[2];
    if (number === undefined)
      return fail("--pr must be a pull request URL or number");
    const worker = yield* callerId(deps.env);
    // Linked first and for any chat, so a worker the owner started by hand is still watched.
    // A worker naming its PR takes it over, as the latest worker on a PR is the one doing it; pr-wake keeps the start of a link the same chat renews.
    const linked = isGitHubPr(args.pr)
      ? yield* Result.await(
          prWake(deps.runTool, deps.env, ["link", args.pr, "--take-over"]),
        )
      : null;
    const watched = typeof linked?.watched === "string" ? linked.watched : null;
    const request = yield* Result.await(launchOfThread(deps.env, worker));
    // Only a launched worker has a title to extend; another chat keeps its own.
    // The number goes last so the title still reads as the task, while a search for the PR finds the worker.
    const title =
      request === null ? null : `${threadTitle("Impl", request)} PR#${number}`;
    const answer =
      title === null
        ? null
        : await callApp(deps.env, worker, "name_thread", { name: title });
    const renamed =
      answer === null || answer.outcome === ("done" satisfies CallOutcome);
    // Fails even after a rename, so a PR the watch cannot see is never taken as watched.
    if (watched === null)
      return fail(
        `${args.pr} is not watched${title === null || !renamed ? "" : ` (the thread is named ${title})`}: ${NOT_LINKABLE}`,
      );
    // A rename the app did not apply leaves the PR watched, which the result says rather than failing.
    return Result.ok<Fields>({
      threadId: worker,
      title: renamed ? title : null,
      watched,
      ...(renamed
        ? {}
        : {
            renameError: `name_thread was not applied: ${JSON.stringify(answer)}`,
          }),
      // pr-wake warns about a linked chat nothing can send to, which the link alone would show as watched.
      ...(typeof linked?.warning === "string"
        ? { warning: linked.warning }
        : {}),
    });
  });

// The watch belongs to pr-wake; these are the options harnexus-task watch took, passed to pr-wake watch as its subcommands.
const watch = async (args: WatchArgs, deps: TaskDeps) => {
  const refused = refuseInCloud(deps.env, "watch");
  if (refused.isErr()) return Result.err(refused.error);
  if (args.release !== undefined)
    return prWake(deps.runTool, deps.env, ["release", args.release]);
  if (args.status) return prWake(deps.runTool, deps.env, ["status", "--json"]);
  if (args.sender) return prWake(deps.runTool, deps.env, ["sender"]);
  if (args.link !== undefined) {
    if (!isGitHubPr(args.link))
      return fail(`${args.link} is not watched: ${NOT_LINKABLE}`);
    // Without --take-over pr-wake refuses a PR another chat is watched for, as harnexus-task watch --link did.
    return prWake(deps.runTool, deps.env, ["link", args.link]);
  }

  if (args.dryRun)
    return prWake(deps.runTool, deps.env, [
      "dry-run",
      ...args.prs.flatMap((pr) => ["--pr", pr]),
    ]);
  // A LaunchAgent that still runs harnexus-task watch keeps watching, now through pr-wake's engine.
  const engine = await prWakeEngine(deps.env, deps.which);
  if (engine.isErr()) return Result.err(engine.error);
  const exited = await deps.runWatch(engine.value, deps.env);
  if (exited.isErr()) return fail(exited.error.message);
  return exited.value === 0
    ? Result.ok<Fields>({ watch: "stopped" })
    : fail(`${engine.value} watch exited with ${exited.value}`);
};

// Opens a chat that shows a Cloud session through harnexus's own cloud_open, which harnexus-task cloud used to do itself.
const cloud = (args: CloudArgs, deps: TaskDeps) =>
  Result.gen(async function* () {
    yield* refuseInCloud(deps.env, "cloud");
    if (args.project !== undefined)
      yield* singleLine(args.project, "--project");
    const caller = yield* callerId(deps.env);
    const prompt =
      args.promptFile === undefined
        ? undefined
        : yield* Result.await(io(readRegularTextFile(args.promptFile)));
    if (prompt !== undefined && isBlank(prompt))
      return fail("the prompt file is empty");
    const answer = await callApp(deps.env, caller, "cloud_open", {
      cwd: deps.cwd ?? process.cwd(),
      ...(args.link !== undefined && { link: args.link }),
      ...(prompt !== undefined && { prompt }),
      ...(args.project !== undefined && { projectId: args.project }),
      ...(args.title !== undefined && { title: args.title }),
      ...(args.model !== undefined && { model: args.model }),
      ...(args.thinking !== undefined && { thinking: args.thinking }),
    });
    if (answer.outcome === "done" && isObject(answer.result))
      return Result.ok<Fields>(answer.result);
    // unknown and chat_not_opened leave a session that may run, so the advice is never to send it again.
    const again = UNSENT.has(answer.outcome)
      ? "nothing was sent"
      : "never resend; check the app";
    return fail(
      `cloud_open ${asText(answer.outcome)} (${again}): ${asText(answer.message ?? answer.error ?? answer)}`,
    );
  });

const environment = async (deps: TaskDeps) =>
  (await detectEnvironment(deps.env)).map((found): Fields => ({ ...found }));

type Outcome = Result<unknown, { message: string }>;

type Subcommand = {
  usage: string;
  options: OptionTypes;
  prepare: (
    values: Values,
  ) => Result<(deps: TaskDeps) => Promise<TaskRun>, UsageInvalid>;
};

type Values = Record<string, unknown>;

const subcommand = <Args>(definition: {
  usage: string;
  options: OptionTypes;
  args: (values: Values) => Result<Args, UsageInvalid>;
  run: (args: Args, deps: TaskDeps) => Outcome | Promise<Outcome>;
}): Subcommand => ({
  usage: definition.usage,
  options: definition.options,
  prepare: (values) =>
    definition.args(values).map((args) => async (deps) => {
      const result = await definition.run(args, deps);
      return result.isOk()
        ? { code: 0, stdout: `${JSON.stringify(result.value)}\n`, stderr: "" }
        : {
            code: 1,
            stdout: "",
            stderr: `${deps.name ?? NAME}: ${result.error.message}\n`,
          };
    }),
});

class UsageInvalid extends TaggedError("UsageInvalid")<{
  message: string;
}> {}

const invalid = (message: string) => Result.err(new UsageInvalid({ message }));

const text = (values: Values, key: string) => {
  const value = values[key];
  return typeof value === "string" ? value : undefined;
};

const required = (values: Values, key: string) => {
  const value = text(values, key);
  return value === undefined
    ? invalid(`--${key} is required`)
    : Result.ok(value);
};

const oneOf = <T extends string>(
  values: Values,
  key: string,
  allowed: readonly T[],
) => {
  const value = text(values, key);
  if (value === undefined) return Result.ok(undefined);
  const chosen = allowed.find((each) => each === value);
  return chosen === undefined
    ? invalid(`--${key} must be one of ${allowed.join(", ")}`)
    : Result.ok(chosen);
};

const MODEL_OPTIONS = {
  model: { type: "string" },
  thinking: { type: "string" },
} as const;

// The Python taskctl's subcommands and options, which callers and permission rules already match.
const COMMANDS = {
  launch: subcommand({
    usage: "launch --request REQUEST [--model MODEL] [--thinking THINKING]",
    options: { request: { type: "string" }, ...MODEL_OPTIONS },
    args: (values) =>
      Result.gen(function* () {
        return Result.ok<LaunchArgs>({
          request: yield* required(values, "request"),
          model: text(values, "model"),
          thinking: text(values, "thinking"),
        });
      }),
    run: launch,
  }),
  review: subcommand({
    usage:
      "review --request REQUEST [--model MODEL] [--thinking THINKING] [--update-base] [--recover discard] [--ask FILE]",
    options: {
      request: { type: "string" },
      ask: { type: "string" },
      ...MODEL_OPTIONS,
      "update-base": { type: "boolean" },
      recover: { type: "string" },
    },
    args: (values) =>
      Result.gen(function* () {
        const ask = text(values, "ask");
        // The reviewer keeps the model it was started with, so a question takes no model either.
        if (
          ask !== undefined &&
          (values["update-base"] === true ||
            values.recover !== undefined ||
            values.model !== undefined ||
            values.thinking !== undefined)
        )
          return invalid(
            "--ask takes none of --update-base, --recover, --model and --thinking",
          );
        return Result.ok<ReviewArgs>({
          ask,
          request: yield* required(values, "request"),
          recover: yield* oneOf(values, "recover", ["discard"]),
          model: text(values, "model"),
          thinking: text(values, "thinking"),
          updateBase: values["update-base"] === true,
        });
      }),
    run: review,
  }),
  state: subcommand({
    usage: "state [--request REQUEST]",
    options: { request: { type: "string" } },
    args: (values) =>
      Result.ok<StateArgs>({ request: text(values, "request") }),
    run: state,
  }),
  resolve: subcommand({
    usage:
      "resolve --request REQUEST (--sent | --not-sent) [--thread-id THREAD_ID]",
    options: {
      request: { type: "string" },
      sent: { type: "boolean" },
      "not-sent": { type: "boolean" },
      "thread-id": { type: "string" },
    },
    args: (values) =>
      Result.gen(function* () {
        const request = yield* required(values, "request");
        if (values.sent === values["not-sent"])
          return invalid("exactly one of --sent and --not-sent is required");
        return Result.ok<ResolveArgs>({
          request,
          sent: values.sent === true,
          threadId: text(values, "thread-id"),
        });
      }),
    run: resolve,
  }),
  name: subcommand({
    usage: "name --pr PR",
    options: { pr: { type: "string" } },
    args: (values) =>
      Result.gen(function* () {
        return Result.ok<NameArgs>({ pr: yield* required(values, "pr") });
      }),
    run: name,
  }),
  watch: subcommand({
    usage:
      "watch [--dry-run [--pr PR]... | --release PR | --status | --sender | --link PR]",
    options: {
      "dry-run": { type: "boolean" },
      pr: { type: "string", multiple: true },
      release: { type: "string" },
      status: { type: "boolean" },
      sender: { type: "boolean" },
      link: { type: "string" },
    },
    args: (values) => {
      const args: WatchArgs = {
        dryRun: values["dry-run"] === true,
        prs: Array.isArray(values.pr)
          ? values.pr.filter((pr) => typeof pr === "string")
          : [],
        release: text(values, "release"),
        status: values.status === true,
        sender: values.sender === true,
        link: text(values, "link"),
      };
      if (args.prs.length > 0 && !args.dryRun)
        return invalid("--pr is only for --dry-run");
      const modes = [
        args.release !== undefined,
        args.dryRun,
        args.status,
        args.sender,
        args.link !== undefined,
      ];
      if (modes.filter(Boolean).length > 1)
        return invalid(
          "use only one of --dry-run, --release, --status, --sender and --link",
        );
      return Result.ok(args);
    },
    run: watch,
  }),
  environment: subcommand({
    usage: "environment",
    options: {},
    args: () => Result.ok({}),
    run: (_args, deps) => environment(deps),
  }),
  cloud: subcommand({
    usage:
      "cloud (--link SESSION_OR_URL | --prompt-file FILE) [--project PROJECT_ID] [--title TITLE] [--model MODEL] [--thinking THINKING]",
    options: {
      link: { type: "string" },
      "prompt-file": { type: "string" },
      project: { type: "string" },
      title: { type: "string" },
      ...MODEL_OPTIONS,
    },
    args: (values) => {
      const link = text(values, "link");
      const promptFile = text(values, "prompt-file");
      if ((link === undefined) === (promptFile === undefined))
        return invalid("exactly one of --link and --prompt-file is required");
      return Result.ok<CloudArgs>({
        link,
        promptFile,
        project: text(values, "project"),
        title: text(values, "title"),
        model: text(values, "model"),
        thinking: text(values, "thinking"),
      });
    },
    run: cloud,
  }),
} satisfies Record<string, Subcommand>;

type Command = keyof typeof COMMANDS;

export type TaskRun = { code: number; stdout: string; stderr: string };

// The compiled command runs apart from any checkout, so its help and crash say where to report a bug.
export const FEEDBACK_HINT =
  "To report a bug, open an issue at https://github.com/riii111/taskctl/issues with the command you ran and its output.";

export const runTask = async (
  argv: readonly string[],
  deps: TaskDeps,
): Promise<TaskRun> => {
  const name = deps.name ?? NAME;
  const parsed = parseCommand(argv, name);
  if (parsed.isErr()) {
    const { message, usage, code } = parsed.error;
    return code === 0
      ? { code, stdout: `${usage}${FEEDBACK_HINT}\n`, stderr: "" }
      : { code, stdout: "", stderr: `${usage}${name}: ${message}\n` };
  }

  return await parsed.value(deps);
};

class UsageShown extends TaggedError("UsageShown")<{
  message: string;
  usage: string;
  code: number;
}> {}

const usageOf = (commands: readonly Command[], name: string) =>
  `usage:\n${commands.map((command) => `  ${name} ${COMMANDS[command].usage}\n`).join("")}`;

const isCommand = (value: string | undefined): value is Command =>
  value !== undefined && Object.hasOwn(COMMANDS, value);

const parseCommand = (
  argv: readonly string[],
  name: string,
): Result<(deps: TaskDeps) => Promise<TaskRun>, UsageShown> => {
  const [command, ...rest] = argv;
  const all = Object.keys(COMMANDS) as Command[];
  if (!isCommand(command)) {
    const help = command === "-h" || command === "--help";
    return Result.err(
      new UsageShown({
        message: `expected a subcommand: ${all.join(", ")}`,
        usage: usageOf(all, name),
        code: help ? 0 : 2,
      }),
    );
  }

  const usage = usageOf([command], name);
  const shown = (message: string, code = 2) =>
    Result.err(new UsageShown({ message, usage, code }));
  const { options, prepare } = COMMANDS[command];
  const parsed = parseOptions(rest, {
    ...options,
    help: { type: "boolean", short: "h" },
  });
  if (parsed.isErr()) return shown(parsed.error.message);
  if (parsed.value.help === true) return shown("", 0);
  const prepared = prepare(parsed.value);
  return prepared.isErr()
    ? shown(prepared.error.message)
    : Result.ok(prepared.value);
};
