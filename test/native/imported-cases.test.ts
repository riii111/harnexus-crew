import { describe, expect, test } from "bun:test";
import { access, readFile } from "node:fs/promises";
import { join } from "node:path";

import { z } from "zod";

const ROOT = join(import.meta.dir, "../..");

const MarkdownCases = z.strictObject({
  baseline: z.string().length(40),
  bun: z.string(),
  note: z.string(),
  cases: z.array(
    z.strictObject({
      name: z.string(),
      source: z.string(),
      text: z.string().optional(),
      file: z.string().optional(),
      candidates: z.array(z.string()),
      selected: z.array(z.number().int().nonnegative()),
    }),
  ),
});

const Expect = z.record(z.string(), z.unknown());
const Case = z.looseObject({ id: z.string(), expect: Expect });

const BoundaryCases = z.strictObject({
  baseline: z.string().length(40),
  note: z.string(),
  socket: z.looseObject({ cases: z.array(Case) }),
  process: z.looseObject({ cases: z.array(Case) }),
  stillOpen: z.array(z.string()),
});

const readJson = async (path: string): Promise<unknown> =>
  JSON.parse(await readFile(join(ROOT, path), "utf8"));

describe("imported spike cases", () => {
  test("the Markdown cases are the 63 judged cases and their 102 candidates", async () => {
    const parsed = MarkdownCases.parse(
      await readJson("test/native/markdown-link-judgement.json"),
    );
    expect(parsed.cases).toHaveLength(63);
    expect(parsed.cases.flatMap((item) => item.candidates)).toHaveLength(102);
    for (const item of parsed.cases) {
      expect(item.selected.every((at) => at < item.candidates.length)).toBe(
        true,
      );
      expect([item.text !== undefined, item.file !== undefined]).toContain(
        true,
      );
      if (item.file !== undefined) await access(join(ROOT, item.file));
    }
  });

  test("the boundary cases are the 21 verified cases with unique ids", async () => {
    const parsed = BoundaryCases.parse(
      await readJson("test/native/boundary-cases.json"),
    );
    const ids = [...parsed.socket.cases, ...parsed.process.cases].map(
      (item) => item.id,
    );
    expect(ids).toHaveLength(21);
    expect(new Set(ids).size).toBe(21);
  });

  test.each([
    { name: "socket_server.ts" },
    { name: "socket_server.py" },
    { name: "child.sh" },
    { name: "noexec.sh" },
    { name: "badshebang.sh" },
  ])("the mock $name is in the repository", async ({ name }) => {
    await access(join(ROOT, "test/native/mocks", name));
  });
});
