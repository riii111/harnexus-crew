import { afterEach, describe, expect, test } from "bun:test";
import {
  mkdir,
  readFile,
  realpath,
  symlink,
  writeFile,
} from "node:fs/promises";
import { join } from "node:path";

import { runTask, TASK_DEPS } from "./cli.ts";
import { createFakeCli } from "./testing/fake-cli.ts";

const SKILLS = join(import.meta.dir, "../../test/fixtures/task-skills");
const README = join(import.meta.dir, "../../README.md");

const cleanups: (() => Promise<unknown>)[] = [];

afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

// A worker in T3 Code, whose Codex also sets a CODEX_THREAD_ID of its own.
const fixture = async () => {
  const cli = await createFakeCli("t3", cleanups);
  const { root } = cli;
  const codex = join(root, "codex");
  await mkdir(codex);
  await symlink(SKILLS, join(codex, "skills"));
  await mkdir(join(root, "config/harnexus"), { recursive: true });
  await writeFile(
    join(root, "config/harnexus/task.json"),
    JSON.stringify({
      templates: {
        worker: join(codex, "skills/task-session-launch/references/worker.md"),
        reviewer: join(
          codex,
          "skills/task-review-cycle/references/reviewer.md",
        ),
      },
    }),
  );
  await mkdir(join(root, "review-home"));
  const env: Record<string, string> = {
    HOME: root,
    CODEX_HOME: codex,
    CODEX_THREAD_ID: "codex-own",
    T3CODE_THREAD_ID: "worker",
    T3CODE_HOME: join(root, "t3-home"),
    HARNEXUS_T3_BIN: cli.bin,
    FAKE_DIR: cli.fake,
    HARNEXUS_EXECUTION_ENV: "",
    CODEX_ENVIRONMENT_ID: "",
    CLAUDE_CODE_REMOTE: "",
    // A bridge here would mean the Codex App was asked instead.
    HARNEXUS_CALL_SOCKET: join(root, "none.sock"),
    XDG_CONFIG_HOME: join(root, "config"),
    XDG_STATE_HOME: join(root, "state"),
  };
  const invoke = async (args: string[]) => {
    const run = await runTask(args, {
      ...TASK_DEPS,
      which: () => null,
      env: { ...process.env, ...env },
    });
    return {
      code: run.code,
      out: run.code === 0 ? JSON.parse(run.stdout) : null,
      err: run.stderr,
    };
  };

  const write = async (data: unknown) => {
    const path = join(root, "request.json");
    await writeFile(path, JSON.stringify(data));
    return path;
  };

  const stdin = (n: number) => readFile(join(cli.fake, `stdin.${n}`), "utf8");
  const runs = async () =>
    Number(await readFile(join(cli.fake, "count"), "utf8").catch(() => "0"));
  return { ...cli, codex, env, invoke, write, stdin, runs };
};

const started = (threadId: string) => JSON.stringify({ threadId });
const shown = (model: string) =>
  JSON.stringify({ thread: { threadId: "x", model }, messages: [] });

describe("harnexus-crew environment in T3 Code", () => {
  test("names T3 Code as the app without asking the harnexus socket", async () => {
    const { invoke } = await fixture();

    const found = await invoke(["environment"]);

    expect(found.out).toMatchObject({
      environment: "local",
      source: "T3CODE_THREAD_ID",
      app: "t3",
    });
  });
});

describe("harnexus-crew launch in T3 Code", () => {
  const request = {
    taskId: "TR1",
    documentRefs: [README],
    completionTarget: "draft_pr",
    projectId: "t3-project",
    startingBranch: "feat/base",
  };

  test("starts the worker in a T3 Code worktree and keeps it as the task's worker", async () => {
    const { invoke, write, plan, rawArgs, stdin, runs } = await fixture();
    await plan(1, { out: started("w1") });
    await plan(2, { out: shown("claude-sonnet-5-5") });
    const path = await write(request);

    const first = await invoke(["launch", "--request", path]);
    const again = await invoke(["launch", "--request", path]);
    const state = await invoke(["state", "--request", path]);

    expect([first.code, first.err]).toEqual([0, ""]);
    expect(first.out).toMatchObject({
      tool: "create_thread",
      threadId: "w1",
      model: "claude-sonnet-5-5",
      effort: null,
    });
    expect(await rawArgs(1)).toEqual([
      "thread",
      "start",
      "t3-project",
      "-",
      "--title",
      "Impl TR1",
      "--provider",
      "claudeAgent",
      "--model",
      "claude-sonnet-5-5",
      "--worktree",
      "feat/base",
      "--json",
    ]);
    expect(await stdin(1)).toContain("進めてよい範囲: draft_pr");
    expect(again.out).toMatchObject({ existing: "w1" });
    expect(state.out).toMatchObject({
      kind: "launch",
      workerThreadId: "w1",
      requested: { model: "claude-sonnet-5-5", effort: null },
      actual: { model: "claude-sonnet-5-5", effort: null },
      pending: null,
    });
    expect(await runs()).toBe(2);
  });

  test("refuses a thinking level before starting anything, so the launch can be run again without it", async () => {
    const { invoke, write, plan, runs } = await fixture();
    const path = await write(request);

    const refused = await invoke([
      "launch",
      "--request",
      path,
      "--thinking",
      "high",
    ]);
    await plan(1, { out: started("w1") });
    await plan(2, { out: shown("claude-sonnet-5-5") });
    const retried = await invoke(["launch", "--request", path]);

    expect([refused.code, refused.err]).toEqual([
      1,
      expect.stringContaining("create_thread was not sent"),
    ]);
    expect(refused.err).toContain("thinking");
    expect([retried.code, retried.out?.threadId]).toEqual([0, "w1"]);
    expect(await runs()).toBe(2);
  });

  test("keeps a start whose answer was lost for resolve, never starting it again", async () => {
    const { invoke, write, plan, runs } = await fixture();
    await plan(1, {
      exit: 1,
      stderr: "Could not reach the T3 Code server at http://127.0.0.1:3773.",
    });
    const path = await write(request);

    const lost = await invoke(["launch", "--request", path]);
    const again = await invoke(["launch", "--request", path]);
    const resolved = await invoke([
      "resolve",
      "--request",
      path,
      "--sent",
      "--thread-id",
      "w9",
    ]);

    expect([lost.code, lost.err]).toEqual([
      1,
      expect.stringContaining("never resend"),
    ]);
    expect(again.code).toBe(1);
    expect(resolved.out).toMatchObject({ threadId: "w9" });
    expect(await runs()).toBe(1);
  });
});

const reviewFixture = async () => {
  const base = await fixture();
  // T3 Code keeps a worktree at <repository name>/<branch> under its folder.
  const checkout = join(base.env.T3CODE_HOME ?? "", "worktrees/repo/feat-x");
  await mkdir(checkout, { recursive: true });
  const git = (...args: string[]) => {
    const ran = Bun.spawnSync(
      [
        "git",
        "-C",
        checkout,
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.com",
        "-c",
        "commit.gpgsign=false",
        ...args,
      ],
      { stderr: "pipe" },
    );
    expect(ran.exitCode).toBe(0);
    return ran.stdout.toString().trim();
  };

  const commit = (message: string) => {
    git("commit", "--allow-empty", "-qm", message);
    return git("rev-parse", "HEAD");
  };

  git("init", "-q");
  const initial = commit("test: initial");
  git("branch", "base");
  const data: Record<string, unknown> = {
    taskId: "example",
    workerAI: "Claude",
    projectId: "t3-project",
    checkout,
    baseBranch: "base",
    documentRefs: [README],
    prUrl: null,
  };
  const review = async (extra: string[] = []) =>
    base.invoke(["review", "--request", await base.write(data), ...extra]);
  return { ...base, checkout, commit, initial, data, review };
};

describe("harnexus-crew review in T3 Code", () => {
  test("starts a Codex reviewer in the review home that answers through T3 Code, then sends each new head to it", async () => {
    const { root, plan, rawArgs, stdin, runs, commit, initial, review } =
      await reviewFixture();
    const head = commit("test: candidate");
    await plan(1, { out: started("r1") });
    await plan(2, { out: shown("gpt-6.1-sol") });

    const first = await review();
    const repeated = await review();
    const fixed = commit("test: fix");
    await plan(3, { out: JSON.stringify({ delivery: "queued" }) });
    const again = await review();

    expect([first.code, first.err]).toEqual([0, ""]);
    expect(first.out).toMatchObject({
      tool: "create_thread",
      threadId: "r1",
      model: "gpt-6.1-sol",
    });
    expect(await rawArgs(1)).toEqual([
      "thread",
      "start",
      await realpath(join(root, "review-home")),
      "-",
      "--title",
      "Review example",
      "--provider",
      "codex",
      "--model",
      "gpt-6.1-sol",
      "--json",
    ]);
    const prompt = await stdin(1);
    expect(prompt).toContain(`${initial}...${head}`);
    expect(prompt).toContain("workerのチャットID: worker");
    expect(prompt).toContain(
      await realpath(join(SKILLS, "task-review-cycle/references/reply-T3.md")),
    );
    expect([repeated.code, repeated.err]).toEqual([
      1,
      expect.stringContaining("already sent to reviewer r1"),
    ]);
    expect([again.code, again.out?.tool]).toEqual([
      0,
      "send_message_to_thread",
    ]);
    expect(await rawArgs(3)).toEqual(["thread", "send", "r1", "-", "--json"]);
    expect(await stdin(3)).toContain(`${initial}...${fixed}`);
    expect(await runs()).toBe(3);
  });

  test("takes the worker from T3CODE_THREAD_ID rather than Codex's own thread", async () => {
    const { commit, data, review, runs } = await reviewFixture();
    commit("test: candidate");
    data.workerChatId = "codex-own";

    const refused = await review();

    expect([refused.code, refused.err]).toEqual([
      1,
      expect.stringContaining("must equal T3CODE_THREAD_ID"),
    ]);
    expect(await runs()).toBe(0);
  });

  test("accepts only a checkout in T3 Code's worktrees", async () => {
    const { codex, commit, data, review, runs } = await reviewFixture();
    commit("test: candidate");
    const elsewhere = join(codex, "worktrees/ab12/checkout");
    await mkdir(elsewhere, { recursive: true });
    data.checkout = elsewhere;

    const refused = await review();

    expect([refused.code, refused.err]).toEqual([
      1,
      expect.stringContaining("t3-home/worktrees/<id>/<name>"),
    ]);
    expect(await runs()).toBe(0);
  });

  test("leaves nothing pending when no T3 Code project holds the review home", async () => {
    const { plan, commit, review, runs } = await reviewFixture();
    commit("test: candidate");
    await plan(1, {
      exit: 1,
      stderr:
        "No T3 Code project matches '/x/review-home'. Pass a project id or a path inside a project.",
    });

    const refused = await review();
    await plan(2, { out: started("r1") });
    await plan(3, { out: shown("gpt-6.1-sol") });
    const retried = await review();

    expect([refused.code, refused.err]).toEqual([
      1,
      expect.stringContaining("t3 project add"),
    ]);
    expect([retried.code, retried.out?.threadId]).toEqual([0, "r1"]);
    expect(await runs()).toBe(3);
  });
});

describe("harnexus-crew review in T3 Code with a reviewer template written before T3 Code", () => {
  test("starts no reviewer, naming the missing reply", async () => {
    const { root, commit, review, runs } = await reviewFixture();
    commit("test: candidate");
    await writeFile(
      join(root, "reviewer.md"),
      "{task_id} {base}...{head} [reply](reply-{reply_to}.md)\n",
    );
    await writeFile(join(root, "reply-Claude.md"), "reply\n");
    await writeFile(
      join(root, "config/harnexus/task.json"),
      JSON.stringify({ templates: { reviewer: join(root, "reviewer.md") } }),
    );

    const refused = await review();

    expect([refused.code, refused.err]).toEqual([
      1,
      expect.stringContaining("reply-T3.md, which is not a file"),
    ]);
    expect(await runs()).toBe(0);
  });
});

describe("Codex App commands in T3 Code", () => {
  test.each([
    { name: "name", argv: ["name", "--pr", "1"] },
    {
      name: "watch --link",
      argv: ["watch", "--link", "https://github.com/o/r/pull/1"],
    },
    { name: "cloud", argv: ["cloud", "--link", "session"] },
  ])(
    "refuses $name, which only the Codex App carries out",
    async ({ argv }) => {
      const { invoke, runs } = await fixture();

      const refused = await invoke([...argv]);

      expect([refused.code, refused.err]).toEqual([
        1,
        expect.stringContaining("unavailable in T3 Code"),
      ]);
      expect(await runs()).toBe(0);
    },
  );
});
