import { afterEach, describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

import { createFakeCli } from "../task/testing/fake-cli.ts";
import { callT3, t3Home } from "./t3.ts";

const cleanups: (() => Promise<unknown>)[] = [];

afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

const fixture = async () => {
  const cli = await createFakeCli("t3", cleanups);
  const deps = {
    env: { HARNEXUS_T3_BIN: cli.bin, FAKE_DIR: cli.fake },
    home: cli.root,
    which: () => null,
  };
  const stdin = (n: number) => readFile(join(cli.fake, `stdin.${n}`), "utf8");
  return { ...cli, deps, stdin };
};

const workerTarget = (startingState?: unknown) => ({
  type: "project",
  projectId: "p1",
  environment: {
    type: "worktree",
    ...(startingState === undefined ? {} : { startingState }),
  },
});

const shown = (model: string) =>
  JSON.stringify({ thread: { threadId: "t1", model }, messages: [] });

describe("callT3 create_thread", () => {
  test("starts the thread in a new worktree with the prompt on stdin and reports the model T3 Code shows", async () => {
    const { deps, plan, rawArgs, stdin } = await fixture();
    await plan(1, {
      out: JSON.stringify({ threadId: "t1", projectId: "p1", runId: "r1" }),
    });
    await plan(2, { out: shown("claude-sonnet-5-5") });

    const answer = await callT3(deps, "create_thread", {
      prompt: "--prompt that looks like a flag",
      target: workerTarget({ type: "branch", branchName: "feat/base" }),
      title: "Impl TR1",
      model: "claude-sonnet-5-5",
    });

    expect(answer).toEqual({
      outcome: "done",
      threadId: "t1",
      model: "claude-sonnet-5-5",
      effort: null,
    });
    expect(await rawArgs(1)).toEqual([
      "thread",
      "start",
      "p1",
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
    expect(await stdin(1)).toBe("--prompt that looks like a flag");
    expect(await rawArgs(2)).toEqual([
      "thread",
      "show",
      "t1",
      "--messages",
      "0",
      "--json",
    ]);
  });

  test("starts a worker without a starting branch from the project's HEAD", async () => {
    const { deps, plan, rawArgs } = await fixture();
    await plan(1, { out: JSON.stringify({ threadId: "t1" }) });
    await plan(2, { out: shown("claude-sonnet-5-5") });

    await callT3(deps, "create_thread", {
      prompt: "p",
      target: workerTarget(),
      title: "T",
      model: "claude-sonnet-5-5",
    });

    const args = await rawArgs(1);
    const at = args.indexOf("--worktree");
    expect(args.slice(at, at + 2)).toEqual(["--worktree", "HEAD"]);
  });

  test("refuses a thinking level without running t3", async () => {
    const { deps, fake } = await fixture();

    const answer = await callT3(deps, "create_thread", {
      prompt: "p",
      target: workerTarget(),
      title: "T",
      model: "claude-sonnet-5-5",
      thinking: "high",
    });

    expect(answer).toMatchObject({ outcome: "unsupported" });
    expect(String(answer.error)).toContain("thinking");
    expect(await Bun.file(join(fake, "count")).exists()).toBe(false);
  });

  test.each([
    {
      name: "no running server",
      stderr:
        "No running T3 Code server uses /x/.t3. Start T3 Code, then retry.",
      expected: { outcome: "not_sent" },
      hint: "Start T3 Code",
    },
    {
      name: "a folder no project holds",
      stderr:
        "No T3 Code project matches '/x/review-home'. Pass a project id or a path inside a project.",
      expected: { outcome: "not_sent" },
      hint: "t3 project add",
    },
    {
      name: "a sandbox that blocks the CLI's port",
      stderr: "NetError: Failed to reserve loopback port\n listen EPERM",
      expected: { outcome: "not_sent" },
      hint: "outside the sandbox",
    },
    {
      name: "a failure after the call reached the server",
      stderr: "Could not reach the T3 Code server at http://127.0.0.1:3773.",
      expected: { outcome: "unknown" },
      hint: "Could not reach",
    },
  ])(
    "answers $name as $expected.outcome",
    async ({ stderr, expected, hint }) => {
      const { deps, plan } = await fixture();
      await plan(1, { exit: 1, stderr });

      const answer = await callT3(deps, "create_thread", {
        prompt: "p",
        target: workerTarget(),
        title: "T",
        model: "claude-sonnet-5-5",
      });

      expect(answer).toMatchObject(expected);
      expect(String(answer.error)).toContain(hint);
    },
  );

  test("takes a start that printed no thread as unknown, since a thread may exist", async () => {
    const { deps, plan } = await fixture();
    await plan(1, { out: "Thread started\n" });

    const answer = await callT3(deps, "create_thread", {
      prompt: "p",
      target: workerTarget(),
      title: "T",
      model: "claude-sonnet-5-5",
    });

    expect(answer).toMatchObject({ outcome: "unknown" });
  });

  test("reports no model when T3 Code cannot show the thread it started", async () => {
    const { deps, plan } = await fixture();
    await plan(1, { out: JSON.stringify({ threadId: "t1" }) });
    await plan(2, { exit: 1, stderr: "boom" });

    const answer = await callT3(deps, "create_thread", {
      prompt: "p",
      target: workerTarget(),
      title: "T",
      model: "claude-sonnet-5-5",
    });

    expect(answer).toEqual({
      outcome: "done",
      threadId: "t1",
      model: null,
      effort: null,
    });
  });

  test("sends nothing when the t3 CLI cannot start", async () => {
    const { deps, root } = await fixture();

    const answer = await callT3(
      { ...deps, env: { HARNEXUS_T3_BIN: join(root, "missing") } },
      "create_thread",
      { prompt: "p", target: workerTarget(), title: "T", model: "m" },
    );

    expect(answer).toMatchObject({ outcome: "not_sent" });
    expect(String(answer.error)).toContain("HARNEXUS_T3_BIN");
  });
});

describe("callT3 send_message_to_thread", () => {
  test("queues the prompt on the thread from stdin", async () => {
    const { deps, plan, rawArgs, stdin } = await fixture();
    await plan(1, { out: JSON.stringify({ delivery: "queued" }) });

    const answer = await callT3(deps, "send_message_to_thread", {
      threadId: "t1",
      prompt: "re-review",
    });

    expect(answer).toEqual({ outcome: "done", threadId: "t1" });
    expect(await rawArgs(1)).toEqual(["thread", "send", "t1", "-", "--json"]);
    expect(await stdin(1)).toBe("re-review");
  });

  test.each([
    { name: "a model", args: { model: "gpt-6.1-sol" } },
    { name: "a thinking level", args: { thinking: "high" } },
  ])("refuses $name, which a send cannot change", async ({ args }) => {
    const { deps, fake } = await fixture();

    const answer = await callT3(deps, "send_message_to_thread", {
      threadId: "t1",
      prompt: "p",
      ...args,
    });

    expect(answer).toMatchObject({ outcome: "unsupported" });
    expect(await Bun.file(join(fake, "count")).exists()).toBe(false);
  });
});

describe("callT3", () => {
  test("offers no other App operation", async () => {
    const { deps } = await fixture();

    expect(await callT3(deps, "name_thread", { name: "x" })).toMatchObject({
      outcome: "unsupported",
    });
  });

  test.each([
    { name: "T3CODE_HOME", env: { T3CODE_HOME: "/data/t3" }, home: "/data/t3" },
    { name: "the default", env: {}, home: "/u/.t3" },
    {
      name: "the default over a relative T3CODE_HOME",
      env: { T3CODE_HOME: "t3" },
      home: "/u/.t3",
    },
  ])("finds T3 Code's folder from $name", ({ env, home }) => {
    expect(t3Home(env, "/u")).toBe(home);
  });
});
