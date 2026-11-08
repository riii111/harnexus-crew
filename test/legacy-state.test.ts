import { afterEach, describe, expect, test } from "bun:test";
import {
  cp,
  mkdir,
  readdir,
  readFile,
  realpath,
  rename,
  symlink,
  writeFile,
} from "node:fs/promises";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";

import { runTask, TASK_DEPS } from "../src/task/cli.ts";
import { stateDirectory } from "../src/task/records.ts";
import { createFakeCli } from "../src/task/testing/fake-cli.ts";

// The fixtures are the state harnexus-task wrote at harnexus 8127612, run from its source under /tmp/taskctl-legacy.
// Paths in them read @ROOT@ and @SKILLS@, and directories keyed by a path are moved to the key of the test's own root.
const FIXTURES = join(import.meta.dir, "fixtures/legacy-state");
const SKILLS = join(import.meta.dir, "fixtures/task-skills");
const RECORDED_ROOT = "/tmp/taskctl-legacy";
const REVIEWER = "01a18d52-e03a-74c1-a50e-4e697b47172b";
const BASE = "af314261c610837f3606d61aa2dff1981debda94";
const HEAD_1 = "a6bc63c9fd9d736a274586bb4a3989bc27297649";
const HEAD_2 = "5455abba46706efa2a58a43a55b97e9d40eaa4ec";

const cleanups: (() => Promise<unknown>)[] = [];

afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

// Commits are dated, so the repository has the SHAs the recorded state names.
const git = (dir: string, ...args: string[]) => {
  const at = "2026-11-01T00:00:00Z";
  const ran = Bun.spawnSync(
    [
      "git",
      "-C",
      dir,
      "-c",
      "commit.gpgsign=false",
      "-c",
      "init.defaultBranch=main",
      ...args,
    ],
    {
      env: {
        ...process.env,
        GIT_AUTHOR_NAME: "Test",
        GIT_AUTHOR_EMAIL: "test@example.com",
        GIT_COMMITTER_NAME: "Test",
        GIT_COMMITTER_EMAIL: "test@example.com",
        GIT_AUTHOR_DATE: at,
        GIT_COMMITTER_DATE: at,
      },
      stderr: "pipe",
    },
  );
  expect([ran.exitCode, ran.stderr.toString()]).toEqual([0, ""]);
  return ran.stdout.toString().trim();
};

const repository = async (dir: string) => {
  await mkdir(dir, { recursive: true });
  git(dir, "init", "-q");
  git(dir, "commit", "--allow-empty", "-qm", "test: initial");
  git(dir, "branch", "base");
  git(dir, "commit", "--allow-empty", "-qm", "test: candidate 1");
  expect(git(dir, "rev-parse", "base", "HEAD")).toBe(`${BASE}\n${HEAD_1}`);
};

const commit = (dir: string, message: string) => {
  git(dir, "commit", "--allow-empty", "-qm", message);
  return git(dir, "rev-parse", "HEAD");
};

type Moved = { kind: string; recorded: string; key: (root: string) => string };

// Copies the recorded state under the test's root, after checking each directory is where taskctl looks for its key.
const copyState = async (fixture: string, root: string, moved: Moved[]) => {
  const state = join(root, fixture, "state");
  await cp(join(FIXTURES, fixture, "state"), state, { recursive: true });
  await rename(join(state, "taskctl"), join(state, "harnexus-crew"));
  for (const file of await readdir(state, { recursive: true })) {
    if (!file.endsWith(".json")) continue;
    const path = join(state, file);
    const text = await readFile(path, "utf8");
    await writeFile(
      path,
      text.replaceAll("@ROOT@", root).replaceAll("@SKILLS@", SKILLS),
    );
  }

  for (const { kind, recorded, key } of moved) {
    const recordedEnv = {
      XDG_STATE_HOME: join(RECORDED_ROOT, fixture, "state"),
    };
    expect(
      basename(stateDirectory(recordedEnv, kind, key(RECORDED_ROOT))),
    ).toBe(recorded);
    const env = { XDG_STATE_HOME: state };
    await rename(
      join(state, "harnexus-crew", kind, recorded),
      stateDirectory(env, kind, key(root)),
    );
  }

  return state;
};

const events = (threadId: string, answer: string) =>
  [
    { type: "thread.started", thread_id: threadId },
    { type: "turn.started" },
    {
      type: "item.completed",
      item: { id: "item_0", type: "agent_message", text: answer },
    },
    { type: "turn.completed", usage: { input_tokens: 1, output_tokens: 1 } },
  ]
    .map((event) => JSON.stringify(event))
    .join("\n");

const cloudFixture = async () => {
  const { root, fake, bin, plan, rawArgs } = await createFakeCli(
    "codex",
    cleanups,
  );
  const home = join(root, "cloud");
  const checkout = join(home, "repo");
  await repository(checkout);
  await copyState("cloud", root, [
    {
      kind: "cloud-review",
      recorded: "3e52769db5ac05f8",
      key: (at) => `${at}/cloud/repo\0judged`,
    },
    {
      kind: "cloud-review",
      recorded: "470a1ab24e770f8c",
      key: (at) => `${at}/cloud/repo\0lost`,
    },
  ]);
  await mkdir(join(home, "config/harnexus"), { recursive: true });
  await writeFile(
    join(home, "config/harnexus/task.json"),
    JSON.stringify({
      templates: {
        reviewer: join(SKILLS, "task-review-cycle/references/reviewer.md"),
      },
    }),
  );
  const env = {
    CLAUDE_CODE_REMOTE: "true",
    CLAUDE_CODE_SESSION_ID: "worker-session",
    HARNEXUS_CODEX_BIN: bin,
    FAKE_DIR: fake,
    HOME: home,
    XDG_CONFIG_HOME: join(home, "config"),
    XDG_STATE_HOME: join(home, "state"),
    PATH: process.env.PATH,
  };
  const request = async (taskId: string) => {
    const path = join(home, `${taskId}.json`);
    await writeFile(
      path,
      JSON.stringify({
        taskId,
        workerAI: "Claude",
        checkout,
        baseBranch: "base",
        documentRefs: ["https://example.com/task"],
        prUrl: null,
      }),
    );
    return path;
  };

  const review = async (taskId: string, extra: string[] = []) => {
    const done = await runTask(
      ["review", "--request", await request(taskId), ...extra],
      { ...TASK_DEPS, env },
    );
    return {
      code: done.code,
      out: done.code === 0 ? JSON.parse(done.stdout) : null,
      err: done.stderr,
    };
  };

  return { home, checkout, plan, rawArgs, review };
};

describe("Cloud review state harnexus-task left", () => {
  test("asks the same reviewer and re-reviews a new head with it, from the recorded base", async () => {
    const { home, checkout, plan, rawArgs, review } = await cloudFixture();
    const question = join(home, "ask.md");
    await writeFile(question, "B1 はまだ残っていますか");
    await plan(1, { out: events(REVIEWER, "B1 は残っています。") });
    await plan(2, { out: events(REVIEWER, "判定: LGTM") });

    const asked = await review("judged", ["--ask", question]);
    const head = commit(checkout, "test: fix B1");
    const reviewed = await review("judged");

    expect(asked.out).toMatchObject({
      kind: "reply",
      head: HEAD_1,
      reviewer: REVIEWER,
      answer: "B1 は残っています。",
    });
    expect(reviewed.out).toMatchObject({
      status: "completed",
      verdict: "LGTM",
      base: BASE,
      head,
      reviewer: REVIEWER,
    });
    for (const n of [1, 2])
      expect((await rawArgs(n)).slice(0, 3)).toEqual([
        "exec",
        "resume",
        REVIEWER,
      ]);
  });

  test("holds the review whose result was unknown until it is discarded, then sends it again", async () => {
    const { plan, rawArgs, review } = await cloudFixture();
    await plan(1, { out: events(REVIEWER, "判定: 修正必要") });

    const held = await review("lost");
    const recovered = await review("lost", ["--recover", "discard"]);

    expect([held.code, held.err]).toEqual([
      1,
      expect.stringContaining("--recover discard"),
    ]);
    expect(recovered.out).toMatchObject({
      verdict: "修正必要",
      base: BASE,
      head: HEAD_1,
    });
    expect((await rawArgs(1))[0]).toBe("exec");
    expect(await rawArgs(1)).not.toContain("resume");
  });
});

type Line = Record<string, unknown>;

// A bridge speaking call protocol 1, answering each call with the next planned answer.
const bridge = async (path: string, answers: Line[]) => {
  const calls: Line[] = [];
  const server = createServer((socket) => {
    let data = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      data += chunk;
      if (!data.endsWith("\n")) return;
      const line = JSON.parse(data) as Line;
      if (line.query === "capabilities") {
        socket.end(
          `${JSON.stringify({ version: 1, outcome: "done", operations: ["list_projects", "create_thread", "send_message_to_thread"] })}\n`,
        );
        return;
      }

      calls.push(line);
      socket.end(`${JSON.stringify({ version: 1, ...answers.shift() })}\n`);
    });
  });
  await new Promise<void>((resolve) => server.listen(path, resolve));
  cleanups.push(() => new Promise((resolve) => server.close(resolve)));
  return calls;
};

const appFixture = async (answers: Line[]) => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "taskctl-legacy-")));
  cleanups.push(() => rm(root, { recursive: true, force: true }));
  const home = join(root, "app");
  const codex = join(home, "codex");
  const checkout = join(codex, "worktrees/ab12/checkout");
  await repository(checkout);
  commit(checkout, "test: candidate 2");
  await symlink(SKILLS, join(codex, "skills"));
  await mkdir(join(home, "config/harnexus"), { recursive: true });
  await writeFile(
    join(home, "config/harnexus/task.json"),
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
  const state = await copyState("app", root, [
    {
      kind: "review",
      recorded: "d6efc365839bb319",
      key: (at) => `${at}/app/codex/worktrees/ab12/checkout\nw1`,
    },
  ]);
  const socket = join(root, "call.sock");
  const calls = await bridge(socket, answers);
  const env = {
    CODEX_HOME: codex,
    HARNEXUS_EXECUTION_ENV: "local",
    HARNEXUS_CALL_SOCKET: socket,
    HOME: home,
    XDG_CONFIG_HOME: join(home, "config"),
    XDG_STATE_HOME: state,
  };
  const write = async (name: string, data: unknown) => {
    const path = join(home, name);
    await writeFile(path, JSON.stringify(data));
    return path;
  };

  const launchRequest = await write("launch.json", {
    taskId: "TR1",
    documentRefs: ["https://example.com/task"],
    completionTarget: "draft_pr",
    projectId: "project",
  });
  const reviewRequest = await write("review.json", {
    taskId: "TR1",
    workerAI: "Codex",
    projectId: "project",
    checkout,
    baseBranch: "base",
    documentRefs: ["https://example.com/task"],
    prUrl: null,
  });
  const run = async (args: string[], thread: string) => {
    const done = await runTask(args, {
      ...TASK_DEPS,
      env: { ...process.env, ...env, CODEX_THREAD_ID: thread },
    });
    return {
      code: done.code,
      out: done.code === 0 ? JSON.parse(done.stdout) : null,
      err: done.stderr,
    };
  };

  return { checkout, calls, run, launchRequest, reviewRequest };
};

describe("App task state harnexus-task left", () => {
  test("keeps the launched worker and its reviewer, resolving the re-review whose answer was lost", async () => {
    const { checkout, calls, run, launchRequest, reviewRequest } =
      await appFixture([{ outcome: "done", threadId: "r1" }]);

    const launched = await run(
      ["launch", "--request", launchRequest],
      "caller",
    );
    const held = await run(["review", "--request", reviewRequest], "w1");
    const resolved = await run(
      ["resolve", "--request", reviewRequest, "--sent"],
      "w1",
    );
    const head = commit(checkout, "test: candidate 3");
    const resent = await run(["review", "--request", reviewRequest], "w1");
    const shown = await run(["state", "--request", reviewRequest], "w1");

    expect(launched.out).toEqual({ existing: "w1", state: expect.any(String) });
    expect([held.code, held.err]).toEqual([
      1,
      expect.stringContaining(
        "previous send_message_to_thread ended as unknown; never resend",
      ),
    ]);
    expect(resolved.out).toMatchObject({
      tool: "send_message_to_thread",
      threadId: "r1",
    });
    expect(calls).toEqual([
      {
        version: 1,
        threadId: "w1",
        tool: "send_message_to_thread",
        arguments: {
          prompt: expect.stringContaining(`${BASE}...${head}`),
          threadId: "r1",
        },
      },
    ]);
    expect(resent.code).toBe(0);
    expect(shown.out).toMatchObject({
      reviewerThreadId: "r1",
      workerThreadId: "w1",
      base: BASE,
      head,
      pending: null,
      requested: { model: "gpt-6.1-sol", effort: "medium" },
    });
  });

  test("sends the lost head again to the same reviewer once it is resolved as not sent", async () => {
    const { calls, run, reviewRequest } = await appFixture([
      { outcome: "done", threadId: "r1" },
    ]);

    await run(["resolve", "--request", reviewRequest, "--not-sent"], "w1");
    const resent = await run(["review", "--request", reviewRequest], "w1");

    expect(resent.out).toMatchObject({ threadId: "r1" });
    expect(calls.map((call) => call.arguments)).toEqual([
      {
        prompt: expect.stringContaining(`${BASE}...${HEAD_2}`),
        threadId: "r1",
      },
    ]);
  });
});
