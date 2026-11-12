import { afterEach, describe, expect, test } from "bun:test";
import {
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const binary = process.env["HARNEXUS_CREW_NATIVE"];

type Line = Record<string, unknown>;

const roots: string[] = [];

afterEach(async () => {
  for (const root of roots.splice(0))
    await rm(root, { recursive: true, force: true });
});

// The adapter runs as a process here, because what a bridge relies on is its standard streams and its exit.
if (binary !== undefined) {
  const sandbox = async () => {
    const root = await mkdtemp(join(tmpdir(), "hxn-adapter-"));
    roots.push(root);
    await mkdir(join(root, "home"));
    return root;
  };

  const spawnAdapter = (root: string) =>
    Bun.spawn([binary, "adapter", "serve", "--id", "test"], {
      env: {
        PATH: process.env["PATH"] ?? "/usr/bin:/bin",
        HOME: join(root, "home"),
        XDG_STATE_HOME: join(root, "state"),
      },
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });

  type Adapter = ReturnType<typeof spawnAdapter>;

  const frame = (line: Line) => `${JSON.stringify({ v: 1, ...line })}\n`;

  const hello = (mode: "observe" | "write") =>
    frame({ type: "hello", mode, versions: [1] });

  const ready = frame({ type: "ready", bindings: [], conflicts: [] });

  // The lines the adapter writes, one at a time, as they arrive.
  const outputOf = (adapter: Adapter) => {
    const lines: Line[] = [];
    const decoder = new TextDecoder();
    let rest = "";
    let bad: string | undefined;
    const done = (async () => {
      for await (const chunk of adapter.stdout) {
        rest += decoder.decode(chunk, { stream: true });
        for (;;) {
          const end = rest.indexOf("\n");
          if (end === -1) break;
          const text = rest.slice(0, end);
          rest = rest.slice(end + 1);
          try {
            lines.push(JSON.parse(text) as Line);
          } catch {
            bad = text;
          }
        }
      }
    })();
    const waitFor = async (count: number) => {
      const started = Date.now();
      while (lines.length < count) {
        if (Date.now() - started > 20_000)
          throw new Error(`only ${lines.length} of ${count} lines arrived`);
        await Bun.sleep(2);
      }
    };

    return {
      lines,
      waitFor,
      done: async () => {
        await done;
        return { rest, bad };
      },
    };
  };

  const send = (adapter: Adapter, text: string) => {
    void adapter.stdin.write(text);
    void adapter.stdin.flush();
  };

  const review = (head: string) => [
    {
      type: "assistant",
      uuid: `a-${head}`,
      message: {
        content: [{ type: "tool_use", id: head, name: "Bash", input: {} }],
      },
    },
    {
      type: "user",
      uuid: `u-${head}`,
      message: {
        content: [
          {
            type: "tool_result",
            tool_use_id: head,
            content: JSON.stringify({
              status: "completed",
              reviewer: "R1",
              head,
              answer: `ok ${head}`,
            }),
            is_error: false,
          },
        ],
      },
    },
  ];

  const records = (eventId: string, phase: string, items: unknown[]) =>
    frame({
      type: "event",
      event: "session_records",
      eventId,
      sessionId: "session_one",
      parentThreadId: "parent",
      phase,
      linkedAt: null,
      records: items,
    });

  const openFds = async (pid: number) => {
    // The adapter finishes writing its records after the last line it prints, so a count taken at once can catch a file still open.
    await Bun.sleep(300);
    const proc = await readdir(`/proc/${pid}/fd`).catch(() => undefined);
    if (proc !== undefined) return proc.length;
    const listed = Bun.spawnSync(["lsof", "-p", String(pid)]);
    return listed.stdout.toString().split("\n").filter(Boolean).length;
  };

  describe("the native adapter process", () => {
    test("writes each of many answers given at once as one whole line, and ends after the last when the bridge closes its end", async () => {
      const root = await sandbox();
      const adapter = spawnAdapter(root);
      const output = outputOf(adapter);
      const requests = Array.from({ length: 400 }, (_, index) =>
        frame({
          type: "request",
          id: `h${index}`,
          op: "history",
          threadId: "x",
        }),
      );

      send(adapter, hello("observe") + requests.join(""));
      void adapter.stdin.end();
      const code = await adapter.exited;
      const { rest, bad } = await output.done();
      const errors = await new Response(adapter.stderr).text();

      expect([code, errors, rest, bad]).toEqual([0, "", "", undefined]);
      const answered = output.lines
        .filter((line) => line["type"] === "response")
        .map((line) => line["id"]);
      expect([...answered].sort()).toEqual(
        Array.from({ length: 400 }, (_, index) => `h${index}`).sort(),
      );
      expect(output.lines[0]).toEqual({
        v: 1,
        type: "hello",
        adapterId: "test",
        bindings: [],
      });
    });

    test("ends with exit code 0 when the bridge closes its end with a request unanswered, and keeps the review for the next connection", async () => {
      const root = await sandbox();
      const adapter = spawnAdapter(root);
      const output = outputOf(adapter);

      send(
        adapter,
        hello("write") +
          ready +
          records("e1", "linked", []) +
          records("e2", "continued", review("aaa1111")),
      );
      await output.waitFor(4);
      expect(output.lines.at(-1)?.["op"]).toBe("list_projects");
      void adapter.stdin.end();
      const code = await Promise.race([
        adapter.exited,
        Bun.sleep(15_000).then(() => "still running"),
      ]);
      if (code === "still running") adapter.kill("SIGKILL");

      expect(code).toBe(0);
      const observe = join(root, "state/harnexus-crew/cloud-observe");
      const waiting = JSON.parse(
        await readFile(join(observe, "pending.json"), "utf8"),
      ) as { review: { head: string } }[];
      expect(waiting.map((entry) => entry.review.head)).toEqual(["aaa1111"]);
      const locks = await readdir(join(observe, "locks")).catch(() => []);
      expect(locks.filter((name) => name.endsWith(".lock"))).toEqual([]);
    });

    test("keeps its descriptors and the memory of requests flat over many round trips", async () => {
      const root = await sandbox();
      const reviews = join(root, "home/.local/state/harnexus/cloud-reviews");
      await mkdir(reviews, { recursive: true });
      await writeFile(join(reviews, "chats.json"), '{"R1":"chat-r1"}');
      const adapter = spawnAdapter(root);
      const output = outputOf(adapter);
      send(adapter, hello("write") + ready + records("e0", "linked", []));
      await output.waitFor(2);

      let handled = 2;
      const roundTrip = async (index: number) => {
        // The last record of the previous event leads, so the adapter finds its cursor again.
        const lead = index > 1 ? [review(`h${index - 1}`)[1]] : [];
        send(
          adapter,
          records(`e${index}`, "continued", [...lead, ...review(`h${index}`)]),
        );
        await output.waitFor(handled + 2);
        handled += 2;
        const request = output.lines.at(-1);
        expect(request?.["op"]).toBe("post");
        send(
          adapter,
          frame({ type: "response", id: request?.["id"], outcome: "done" }),
        );
      };

      for (let index = 1; index <= 10; index++) await roundTrip(index);
      const before = await openFds(adapter.pid);
      for (let index = 11; index <= 160; index++) await roundTrip(index);
      const after = await openFds(adapter.pid);
      void adapter.stdin.end();
      const code = await adapter.exited;

      expect([code, after]).toEqual([0, before]);
      expect(output.lines.filter((line) => line["op"] === "post")).toHaveLength(
        160,
      );
    });
  });
}
