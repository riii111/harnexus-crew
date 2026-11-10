import { join } from "node:path";

import { parseJson } from "../lib/json.boundary.ts";
import { type Fields, isObject } from "../lib/object.ts";
import { runProcess } from "../lib/run.boundary.ts";
import type { CallOutcome } from "./call.ts";

type Env = Record<string, string | undefined>;

export type T3Deps = {
  env: Env;
  home: string;
  which: (name: string) => string | null;
};

// Carries the harnexus App operations a task sends to T3 Code's t3 CLI, answering with the same outcomes.
export const callT3 = (
  deps: T3Deps,
  tool: string,
  args: Fields,
): Promise<Fields> => {
  if (tool === "create_thread") return startThread(deps, args);
  if (tool === "send_message_to_thread") return sendMessage(deps, args);
  return Promise.resolve(unsupported(`T3 Code does not offer ${tool}`));
};

// The data directory the t3 CLI reads, as the CLI resolves it.
export const t3Home = (env: Env, home: string) => {
  const set = env[HOME_ENV];
  return set?.startsWith("/") ? set : join(home, ".t3");
};

// T3 Code creates the worktree before it answers, so a start waits longer than a send.
const START_TIMEOUT_MS = 3 * 60_000;
const SEND_TIMEOUT_MS = 60_000;
const SHOW_TIMEOUT_MS = 30_000;

const NO_THINKING =
  "T3 Code's t3 CLI cannot set a thinking level; leave out --thinking, and set it in T3 Code instead";

const startThread = async (deps: T3Deps, args: Fields): Promise<Fields> => {
  if (args.thinking !== undefined) return unsupported(NO_THINKING);
  const prompt = text(args, "prompt");
  const title = text(args, "title");
  const model = text(args, "model");
  const target = isObject(args.target) ? args.target : {};
  const project = text(target, "projectId");
  if (prompt === null || title === null || model === null || project === null)
    return unsent("create_thread needs prompt, title, model and a project");

  const base = worktreeBase(target);
  const ran = await runT3(
    deps,
    [
      "thread",
      "start",
      project,
      "-",
      "--title",
      title,
      "--provider",
      providerOf(model),
      "--model",
      model,
      ...(base === null ? [] : ["--worktree", base]),
      "--json",
    ],
    prompt,
    START_TIMEOUT_MS,
  );
  if (!ran.ok) return ran.answer;

  const threadId = printed(ran.stdout)?.threadId;
  if (typeof threadId !== "string")
    return unknown(
      `t3 thread start answered without a thread: ${brief(ran.stdout)}`,
    );
  return {
    outcome: "done" satisfies CallOutcome,
    threadId,
    model: await modelOf(deps, threadId),
    effort: null,
  };
};

const sendMessage = async (deps: T3Deps, args: Fields): Promise<Fields> => {
  // A send cannot change the thread's settings, so a model or thinking for it is refused rather than dropped.
  if (args.thinking !== undefined) return unsupported(NO_THINKING);
  if (args.model !== undefined)
    return unsupported(
      "T3 Code's t3 CLI cannot change a thread's model; leave out --model, and change it in T3 Code instead",
    );
  const threadId = text(args, "threadId");
  const prompt = text(args, "prompt");
  if (threadId === null || prompt === null)
    return unsent("send_message_to_thread needs threadId and prompt");

  const ran = await runT3(
    deps,
    ["thread", "send", threadId, "-", "--json"],
    prompt,
    SEND_TIMEOUT_MS,
  );
  return ran.ok
    ? { outcome: "done" satisfies CallOutcome, threadId }
    : ran.answer;
};

// A Codex App worker starts from the project's checked-out branch, and T3 Code needs that base named.
const DEFAULT_WORKTREE_BASE = "HEAD";

const worktreeBase = (target: Fields) => {
  const environment = isObject(target.environment) ? target.environment : {};
  if (environment.type !== "worktree") return null;
  const state = isObject(environment.startingState)
    ? environment.startingState
    : {};
  return typeof state.branchName === "string"
    ? state.branchName
    : DEFAULT_WORKTREE_BASE;
};

// The provider instances T3 Code creates for Claude Code and Codex.
const CLAUDE_PROVIDER = "claudeAgent";
const CODEX_PROVIDER = "codex";

const providerOf = (model: string) =>
  model.startsWith("claude-") ? CLAUDE_PROVIDER : CODEX_PROVIDER;

// The model the thread runs on as T3 Code reports it, or null when it cannot tell.
const modelOf = async (deps: T3Deps, threadId: string) => {
  const ran = await runT3(
    deps,
    ["thread", "show", threadId, "--messages", "0", "--json"],
    "",
    SHOW_TIMEOUT_MS,
  );
  const shown = ran.ok ? printed(ran.stdout) : null;
  const thread = isObject(shown?.thread) ? shown.thread : {};
  return typeof thread.model === "string" ? thread.model : null;
};

type Ran = { ok: true; stdout: string } | { ok: false; answer: Fields };

const KILL_GRACE_MS = 5_000;

const runT3 = async (
  deps: T3Deps,
  args: string[],
  input: string,
  timeoutMs: number,
): Promise<Ran> => {
  const bin = binary(deps);
  if (!bin.ok) return { ok: false, answer: unsent(bin.error) };

  const ran = await runProcess(bin.path, args, input, {
    cwd: deps.home,
    env: deps.env,
    timeoutMs,
    killGraceMs: KILL_GRACE_MS,
  });
  if (ran.isErr())
    return {
      ok: false,
      answer: ran.error.started
        ? unknown(`no answer: ${ran.error.message}`)
        : unsent(
            `${ran.error.message}; install T3 Code, or set ${BIN_ENV} to its t3 CLI`,
          ),
    };
  const { status, stdout, stderr, ended } = ran.value;
  if (ended !== "exit")
    return {
      ok: false,
      answer: unknown(`no answer: t3 ${args[0]} ${args[1]} ended by ${ended}`),
    };
  if (status === 0) return { ok: true, stdout };

  const reason = brief(stderr) || `t3 exited with ${status}`;
  for (const [pattern, hint] of BEFORE_SENDING)
    if (pattern.test(stderr))
      return {
        ok: false,
        answer: unsent(hint === null ? reason : `${reason}; ${hint}`),
      };
  return { ok: false, answer: unknown(reason) };
};

// Failures the CLI reports before it reaches the server or that the server says left nothing behind; any other failure may come after the thread was made or the message queued.
const BEFORE_SENDING: readonly [RegExp, string | null][] = [
  [/No running T3 Code server/, null],
  [
    /No T3 Code project matches/,
    "add the folder to T3 Code as a project with `t3 project add <path>`",
  ],
  [/No thread was created/, null],
  [/Failed to reserve loopback port|listen EPERM/, "run outside the sandbox"],
];

const BIN_ENV = "HARNEXUS_T3_BIN";
const HOME_ENV = "T3CODE_HOME";

type Binary = { ok: true; path: string } | { ok: false; error: string };

const binary = ({ env, home, which }: T3Deps): Binary => {
  const set = env[BIN_ENV];
  if (set !== undefined && set !== "")
    return set.startsWith("/")
      ? { ok: true, path: set }
      : { ok: false, error: `${BIN_ENV} must be an absolute path` };
  // The desktop app writes its launcher here without putting it on PATH, so a t3 on PATH is preferred and this one is the fallback.
  return { ok: true, path: which("t3") ?? join(t3Home(env, home), "bin/t3") };
};

// The one JSON object a --json command prints, on its last line.
const printed = (stdout: string) => {
  const last = stdout.trim().split("\n").at(-1) ?? "";
  const parsed = parseJson(last).unwrapOr(null);
  return isObject(parsed) ? parsed : null;
};

const text = (args: Fields, key: string) => {
  const value = args[key];
  return typeof value === "string" ? value : null;
};

const brief = (text: string) => text.trim().slice(0, 500);

const unsent = (error: string): Fields => ({
  outcome: "not_sent" satisfies CallOutcome,
  error,
});

const unsupported = (error: string): Fields => ({
  outcome: "unsupported" satisfies CallOutcome,
  error,
});

const unknown = (error: string): Fields => ({
  outcome: "unknown" satisfies CallOutcome,
  error,
});
