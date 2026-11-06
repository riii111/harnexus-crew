import { afterEach, describe, expect, test } from "bun:test";
import {
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { runAdapterCommand } from "./command.ts";

const ENTRY = join(import.meta.dir, "../../cli/task.ts");

const cleanups: (() => Promise<unknown>)[] = [];

afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

const home = async () => {
  const root = await realpath(
    await mkdtemp(join(tmpdir(), "taskctl-command-")),
  );
  cleanups.push(() => rm(root, { recursive: true, force: true }));
  return {
    root,
    env: {
      HOME: root,
      XDG_STATE_HOME: join(root, "state"),
      HARNEXUS_STATE_PATH: join(root, "harnexus/threads.json"),
    },
  };
};

describe("taskctl adapter export-links and import-links", () => {
  const chatFiles = async (root: string) => {
    const chats = join(root, "state/taskctl/cloud-chats");
    await mkdir(chats, { recursive: true });
    const write = (name: string, value: unknown) =>
      writeFile(join(chats, `${name}.json`), JSON.stringify(value));
    const read = async (name: string) =>
      JSON.parse(await readFile(join(chats, `${name}.json`), "utf8"));
    return { chats, write, read };
  };

  test("carries harnexus-task cloud's chats, a reservation of unknown outcome among them, out and back unchanged", async () => {
    const { root, env } = await home();
    const { chats, write, read } = await chatFiles(root);
    const opened = { threadId: "chat-a", openedAt: "2026-11-01T00:00:00Z" };
    const reserved = { threadId: null, startedAt: "2026-11-02T00:00:00Z" };
    await write("session_A", opened);
    await write("session_B", reserved);

    const exported = await runAdapterCommand(["export-links"], env, "taskctl");
    await rm(chats, { recursive: true });
    const file = join(root, "links.json");
    await writeFile(file, exported.stdout);
    const imported = await runAdapterCommand(
      ["import-links", file],
      env,
      "taskctl",
    );

    expect(JSON.parse(exported.stdout)).toEqual({
      version: 1,
      links: [
        {
          sessionId: "session_A",
          threadId: "chat-a",
          reservedAt: "2026-11-01T00:00:00Z",
        },
        {
          sessionId: "session_B",
          threadId: null,
          reservedAt: "2026-11-02T00:00:00Z",
        },
      ],
    });
    expect(JSON.parse(imported.stdout)).toEqual({ written: 2, kept: 0 });
    expect([await read("session_A"), await read("session_B")]).toEqual([
      opened,
      reserved,
    ]);
  });

  test("adds what is missing, names a reserved chat once it is known, and never replaces a chat already recorded", async () => {
    const { root, env } = await home();
    const { write, read } = await chatFiles(root);
    await write("session_A", {
      threadId: "chat-a",
      openedAt: "2026-11-01T00:00:00Z",
    });
    await write("session_B", {
      threadId: null,
      startedAt: "2026-11-02T00:00:00Z",
    });
    const file = join(root, "links.json");
    const importing = async (links: unknown[]) => {
      await writeFile(file, JSON.stringify({ version: 1, links }));
      return runAdapterCommand(["import-links", file], env, "taskctl");
    };

    const merged = await importing([
      {
        sessionId: "session_A",
        threadId: null,
        reservedAt: "2026-11-05T00:00:00Z",
      },
      {
        sessionId: "session_B",
        threadId: "chat-b",
        reservedAt: "2026-11-03T00:00:00Z",
      },
      {
        sessionId: "session_C",
        threadId: null,
        reservedAt: "2026-11-04T00:00:00Z",
      },
    ]);
    const conflicting = await importing([
      {
        sessionId: "session_A",
        threadId: "chat-x",
        reservedAt: "2026-11-05T00:00:00Z",
      },
    ]);

    expect(JSON.parse(merged.stdout)).toEqual({ written: 2, kept: 1 });
    expect(await read("session_A")).toEqual({
      threadId: "chat-a",
      openedAt: "2026-11-01T00:00:00Z",
    });
    expect(await read("session_B")).toEqual({
      threadId: "chat-b",
      openedAt: "2026-11-03T00:00:00Z",
    });
    expect(await read("session_C")).toEqual({
      threadId: null,
      startedAt: "2026-11-04T00:00:00Z",
    });
    expect([conflicting.code, conflicting.stderr]).toEqual([
      1,
      expect.stringContaining("kept the chats already recorded for session_A"),
    ]);
    expect(await read("session_A")).toEqual({
      threadId: "chat-a",
      openedAt: "2026-11-01T00:00:00Z",
    });
  });

  test.each([
    { name: "a file without a version", value: { links: [] } },
    {
      name: "a session named twice",
      value: {
        version: 1,
        links: [
          { sessionId: "session_A", threadId: null, reservedAt: "x" },
          { sessionId: "session_A", threadId: "chat-a", reservedAt: "x" },
        ],
      },
    },
    {
      name: "a link without its reservation time",
      value: {
        version: 1,
        links: [{ sessionId: "session_A", threadId: null }],
      },
    },
  ])("refuses $name", async ({ value }) => {
    const { root, env } = await home();
    const file = join(root, "links.json");
    await writeFile(file, JSON.stringify(value));

    const refused = await runAdapterCommand(
      ["import-links", file],
      env,
      "taskctl",
    );

    expect([refused.code, refused.stderr]).toEqual([
      1,
      expect.stringContaining(
        'expected {"version":1,"links":[{"sessionId","threadId","reservedAt"}]}',
      ),
    ]);
  });
});

describe("taskctl adapter serve", () => {
  test("answers the bridge's hello on stdout and ends when the bridge closes stdin", async () => {
    const { env } = await home();
    const child = Bun.spawn(
      ["bun", ENTRY, "adapter", "serve", "--id", "taskctl"],
      {
        env: { PATH: process.env.PATH, ...env },
        stdin: "pipe",
        stdout: "pipe",
        stderr: "pipe",
      },
    );
    void child.stdin.write(
      `${JSON.stringify({ v: 1, type: "hello", bridgeId: "b1", adapterId: "taskctl", mode: "observe", versions: [1] })}\n`,
    );
    void child.stdin.end();

    const code = await child.exited;
    const out = await new Response(child.stdout).text();

    expect(code).toBe(0);
    expect(
      out
        .trim()
        .split("\n")
        .map((line) => JSON.parse(line)),
    ).toEqual([{ v: 1, type: "hello", adapterId: "taskctl", bindings: [] }]);
  });

  test("refuses to serve without an adapter id", async () => {
    const { env } = await home();

    const refused = await runAdapterCommand(["serve"], env, "taskctl");

    expect([refused.code, refused.stderr]).toEqual([
      2,
      expect.stringContaining("--id ADAPTER_ID is required"),
    ]);
  });
});
