import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const probePath = process.env["HARNEXUS_STORE_PROBE"];

type Reply = Record<string, unknown>;

// The store runs as separate processes here, because locks and atomic writes are promises about other processes.
if (probePath !== undefined) {
  let root: string;
  let counter = 0;

  beforeAll(async () => {
    root = await mkdtemp(join(tmpdir(), "harnexus-store-"));
  });

  afterAll(async () => {
    await rm(root, { recursive: true, force: true });
  });

  const sandbox = async () => {
    counter += 1;
    const directory = join(root, `case-${counter}`);
    await mkdir(directory);
    return directory;
  };

  const start = (...args: string[]) =>
    Bun.spawn([probePath, ...args], { stdout: "pipe", stderr: "pipe" });

  const reply = async (process: ReturnType<typeof start>): Promise<Reply> => {
    const [text, errors, code] = await Promise.all([
      new Response(process.stdout).text(),
      new Response(process.stderr).text(),
      process.exited,
    ]);
    if (code !== 0) throw new Error(`probe exited ${code}: ${errors}`);
    return JSON.parse(text.trim().split("\n").at(-1) ?? "") as Reply;
  };

  const run = (...args: string[]) => reply(start(...args));

  // Processes started one by one begin together at a time a little ahead.
  const soon = () => String(Date.now() + 1500);

  const text = (value: unknown) => String(value);

  const deadPid = async () => {
    const finished = Bun.spawn(["true"]);
    await finished.exited;
    return finished.pid;
  };

  const leaveLock = (lock: string, pid: number) =>
    writeFile(lock, JSON.stringify({ pid, token: "dead" }));

  const exists = (path: string) =>
    stat(path).then(
      () => true,
      () => false,
    );

  const tokenIn = async (lock: string) =>
    (JSON.parse(await readFile(lock, "utf8")) as { token: string }).token;

  describe("the lock between processes", () => {
    test("of several runs started together only one takes the lock", async () => {
      const directory = await sandbox();
      const lock = join(directory, "lock.json");
      const at = soon();

      const replies = await Promise.all(
        Array.from({ length: 16 }, () =>
          run("acquire", lock, "review", "600", at),
        ),
      );

      const taken = replies.filter((answer) => answer["ok"] === true);
      expect(taken).toHaveLength(1);
      for (const answer of replies.filter((item) => item["ok"] === false))
        expect(text(answer["message"])).toMatch(
          /^another review( \(pid \d+\))? is using this session$/,
        );
      expect(await exists(lock)).toBe(false);
    });

    test("runs racing for a dead holder's lock never hold it together", async () => {
      const directory = await sandbox();
      const lock = join(directory, "lock.json");
      await leaveLock(lock, await deadPid());
      const at = soon();

      const replies = await Promise.all(
        Array.from({ length: 12 }, () =>
          run("acquire", lock, "review", "150", at),
        ),
      );

      const spans = replies
        .filter((answer) => answer["ok"] === true)
        .map((answer) => [Number(answer["from"]), Number(answer["to"])])
        .sort((a, b) => (a[0] ?? 0) - (b[0] ?? 0));
      expect(spans.length).toBeGreaterThanOrEqual(1);
      for (let index = 1; index < spans.length; index++)
        expect(spans[index]?.[0]).toBeGreaterThanOrEqual(
          spans[index - 1]?.[1] ?? 0,
        );
      expect(await exists(`${lock}.reap`)).toBe(false);
      expect((await run("acquire", lock, "review", "0", "0"))["ok"]).toBe(true);
    });

    test("a killed holder's lock is taken over and the new holder's token differs", async () => {
      const directory = await sandbox();
      const lock = join(directory, "lock.json");
      const holder = start("hold", lock, "review");
      const reader = holder.stdout.getReader();
      const first = await reader.read();
      const held = JSON.parse(new TextDecoder().decode(first.value)) as Reply;
      expect(held["ok"]).toBe(true);

      holder.kill("SIGKILL");
      await holder.exited;
      const taken = await run("acquire", lock, "review", "0", "0");

      expect(taken["ok"]).toBe(true);
      expect(taken["token"]).not.toBe(held["token"]);
    });

    test("a run that died while taking over leaves the lock closed until its marker is removed", async () => {
      const directory = await sandbox();
      const lock = join(directory, "lock.json");
      const marker = `${lock}.reap`;
      await leaveLock(lock, await deadPid());
      expect((await run("marker-die", lock))["ok"]).toBe(true);
      const at = soon();

      const replies = await Promise.all(
        Array.from({ length: 6 }, () =>
          run("acquire", lock, "review", "0", at),
        ),
      );

      for (const answer of replies) {
        expect(answer["ok"]).toBe(false);
        expect(text(answer["message"])).toContain(`left ${lock} and ${marker}`);
      }

      expect(await tokenIn(lock)).toBe("dead");

      await rm(marker);
      expect((await run("acquire", lock, "review", "0", "0"))["ok"]).toBe(true);
    });

    test("work under the lock loses no update across processes", async () => {
      const directory = await sandbox();
      const locks = join(directory, "locks");
      const counterFile = join(directory, "counter");
      const at = soon();

      const replies = await Promise.all(
        Array.from({ length: 6 }, () =>
          run("with-lock", locks, "chats", counterFile, "15", at, "20000"),
        ),
      );

      for (const answer of replies) expect(answer["ok"]).toBe(true);
      expect(await readFile(counterFile, "utf8")).toBe("90");
      expect(await readdir(locks)).toEqual([]);
    });

    test("a run that waits longer than allowed fails and names the holder", async () => {
      const directory = await sandbox();
      const locks = join(directory, "locks");
      await mkdir(locks);
      const holder = start("hold", join(locks, "chats.lock"), "review");
      await holder.stdout.getReader().read();

      const waited = await run(
        "with-lock",
        locks,
        "chats",
        join(directory, "counter"),
        "1",
        "0",
        "300",
      );
      holder.kill("SIGKILL");
      await holder.exited;

      expect(waited["ok"]).toBe(false);
      expect(text(waited["message"])).toMatch(
        /chats\.lock stayed locked: another harnexus-crew adapter \(pid \d+\) is using this session$/,
      );
    });
  });

  describe("files written by several processes", () => {
    test("of several writers only one creates the file, with its whole content", async () => {
      const directory = await sandbox();
      const target = join(directory, "created.json");
      const at = soon();
      const contents = Array.from({ length: 16 }, (_, index) =>
        String(index).repeat(200000),
      );

      const replies = await Promise.all(
        contents.map((_, index) =>
          run("exclusive", target, String(index), "200000", at),
        ),
      );

      expect(
        replies.filter((answer) => answer["created"] === true),
      ).toHaveLength(1);
      const winner = replies.findIndex((answer) => answer["created"] === true);
      expect(await readFile(target, "utf8")).toBe(contents[winner] ?? "");
      expect(await readdir(directory)).toEqual(["created.json"]);
    });

    test("a reader sees a whole file even when writers are killed in the middle", async () => {
      const directory = await sandbox();
      const target = join(directory, "state.json");
      const size = 262144;
      const writers = ["a", "b", "c", "d"].map((letter) =>
        start("atomic-loop", target, letter, String(size), "1500"),
      );
      await writeFile(target, "a".repeat(size));
      const torn: string[] = [];
      const until = Date.now() + 1200;
      let reads = 0;
      let killed = false;

      while (Date.now() < until) {
        const seen = await readFile(target, "utf8");
        reads += 1;
        if (seen.length !== size || !/^(.)\1*$/s.test(seen))
          torn.push(seen.slice(0, 20));
        if (!killed && reads > 20) {
          writers[1]?.kill("SIGKILL");
          writers[3]?.kill("SIGKILL");
          killed = true;
        }
      }

      const survivors = await Promise.all(
        [writers[0], writers[2]].map((writer) => {
          if (writer === undefined) throw new Error("writer is missing");
          return reply(writer);
        }),
      );
      await Promise.all(writers.map((writer) => writer.exited));

      for (const answer of survivors)
        expect(Number(answer["writes"])).toBeGreaterThan(0);
      expect(torn).toEqual([]);
      expect(reads).toBeGreaterThan(20);
      const last = await readFile(target, "utf8");
      expect(last).toMatch(/^(.)\1*$/s);
      expect(last).toHaveLength(size);
      expect(
        (await readdir(directory)).filter((name) => !name.endsWith(".tmp")),
      ).toEqual(["state.json"]);
    });

    test("lines appended by several processes arrive whole", async () => {
      const directory = await sandbox();
      const journal = join(directory, "logs", "journal.jsonl");
      const at = soon();

      const replies = await Promise.all(
        ["p0", "p1", "p2", "p3", "p4"].map((name) =>
          run(
            "append",
            journal,
            `{"from":"${name}","pad":"${"x".repeat(5000)}"}`,
            "40",
            at,
          ),
        ),
      );

      for (const answer of replies) expect(answer["ok"]).toBe(true);
      const lines = (await readFile(journal, "utf8")).split("\n");
      expect(lines.pop()).toBe("");
      expect(lines).toHaveLength(200);
      const counts = new Map<string, number>();
      for (const line of lines) {
        const entry = JSON.parse(line) as { from: string };
        counts.set(entry.from, (counts.get(entry.from) ?? 0) + 1);
      }

      expect([...counts.values()]).toEqual([40, 40, 40, 40, 40]);
    });
  });

  describe("reading and writing files", () => {
    test("text is read as Node reads it, including a byte order mark and invalid bytes", async () => {
      const directory = await sandbox();
      const samples: Record<string, Uint8Array> = {
        bom: new Uint8Array([0xef, 0xbb, 0xbf, 0x61]),
        invalid: new Uint8Array([0x61, 0xff, 0x62, 0xc3, 0x28, 0x63]),
        truncated: new Uint8Array([0x61, 0xe3, 0x81]),
        surrogate: new Uint8Array([0xed, 0xa0, 0x80, 0x61]),
        nul: new Uint8Array([0x61, 0x00, 0x62]),
        empty: new Uint8Array([]),
        japanese: new TextEncoder().encode("日本語\n😀"),
        large: new TextEncoder().encode("0123456789".repeat(30000)),
      };

      for (const [name, bytes] of Object.entries(samples)) {
        const path = join(directory, name);
        await writeFile(path, bytes);

        const answer = await run("read", path);

        expect(answer["text"]).toBe(await readFile(path, "utf8"));
      }
    });

    test("a missing file reads as null and a FIFO is refused without waiting", async () => {
      const directory = await sandbox();
      const fifo = join(directory, "fifo");
      expect(Bun.spawnSync(["mkfifo", fifo]).exitCode).toBe(0);

      expect(
        (await run("read", join(directory, "missing")))["text"],
      ).toBeNull();
      const refused = await run("read-regular", fifo);

      expect(text(refused["message"])).toBe(`cannot read ${fifo}`);
    });

    test("a record is written as JSON.stringify with one space of indent", async () => {
      const directory = await sandbox();
      const documents = [
        "{}",
        "[]",
        "null",
        '{"a":[],"b":{},"c":[[],{}],"d":[{"e":1,"f":[2,3,[4]]}]}',
        '{"text":"line\\nbreak \\"quoted\\" \\\\ back \\u0001 \\u2028 \\ud83d\\ude00 日本語","n":[0,-0,1.5,1e21,1e-7,123456789012345678901,0.1,-2.5e-10,1e400]}',
        '{"b":1,"a":2,"10":3,"2":4,"-1":5,"01":6,"4294967295":7,"4294967294":8}',
        '{"dup":1,"dup":2,"k":{"dup":3,"dup":4}}',
        '{"colon:key,":"x:y,[{}]","[":"]","{":"}"}',
        '{"deep":[[[[[[[[{"x":[[[]]]}]]]]]]]]}',
      ];

      for (const [index, source] of documents.entries()) {
        const path = join(directory, "nested", `${index}.json`);

        const answer = await run("save-json", path, source, "replace");

        expect(answer["ok"]).toBe(true);
        expect(await readFile(path, "utf8")).toBe(
          JSON.stringify(JSON.parse(source), null, 1),
        );
      }
    });

    test("a record file is owner-only and so is the directory made for it", async () => {
      const directory = await sandbox();
      const path = join(directory, "made", "deeper", "state.json");

      await run("save-json", path, '{"a":1}', "replace");

      expect((await stat(path)).mode & 0o777).toBe(0o600);
      expect((await stat(join(directory, "made", "deeper"))).mode & 0o777).toBe(
        0o700,
      );
      expect((await stat(join(directory, "made"))).mode & 0o777).toBe(0o700);
    });

    test("an exclusive record is refused when one exists", async () => {
      const directory = await sandbox();
      const path = join(directory, "pending.json");

      const first = await run("save-json", path, '{"a":1}', "exclusive");
      const second = await run("save-json", path, '{"a":2}', "exclusive");

      expect(first["ok"]).toBe(true);
      expect(second["message"]).toBe(
        `another harnexus-crew run is sending; inspect ${path}`,
      );
      expect(JSON.parse(await readFile(path, "utf8"))).toEqual({ a: 1 });
    });
  });

  describe("state directories", () => {
    test.each([
      { name: "a path key", kind: "launch", key: "/Users/x/work\ntask-1" },
      { name: "a Japanese key", kind: "review", key: "日本語のキー😀" },
      { name: "an empty key", kind: "review", key: "" },
    ])(
      "$name is named as the TypeScript build names it",
      async ({ kind, key }) => {
        const answer = await run(
          "state-directory",
          "/state/harnexus-crew",
          kind,
          key,
        );

        expect(answer["path"]).toBe(
          join(
            "/state/harnexus-crew",
            kind,
            createHash("sha256").update(key).digest("hex").slice(0, 16),
          ),
        );
      },
    );
  });
}
