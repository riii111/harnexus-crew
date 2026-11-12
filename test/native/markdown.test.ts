import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { z } from "zod";

const probePath = process.env["HARNEXUS_MARKDOWN_PROBE"];
const ROOT = join(import.meta.dir, "../..");

const Judgement = z.strictObject({
  baseline: z.string(),
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

const Reply = z.union([
  z.strictObject({
    selected: z.array(
      z.strictObject({ index: z.number().int(), raw: z.string() }),
    ),
  }),
  z.strictObject({ error: z.string() }),
]);

// The judgements are the TS build's, made by Bun.markdown.render on the template with its link targets swapped for markers.
if (probePath !== undefined) {
  let directory: string;

  beforeAll(async () => {
    directory = await mkdtemp(join(tmpdir(), "harnexus-markdown-"));
  });

  afterAll(async () => {
    await rm(directory, { recursive: true, force: true });
  });

  const judge = async (template: string) => {
    const path = join(directory, "template.md");
    await writeFile(path, template);
    const process = Bun.spawn([probePath, path], {
      stdout: "pipe",
      stderr: "pipe",
    });
    const [text, errors, code] = await Promise.all([
      new Response(process.stdout).text(),
      new Response(process.stderr).text(),
      process.exited,
    ]);
    if (code !== 0) throw new Error(`probe exited ${code}: ${errors}`);
    return Reply.parse(JSON.parse(text));
  };

  const judgement = Judgement.parse(
    JSON.parse(
      await readFile(
        join(ROOT, "test/native/markdown-link-judgement.json"),
        "utf8",
      ),
    ),
  );

  describe("the Markdown link judgement", () => {
    test.each(judgement.cases)("$name", async (item) => {
      const template =
        item.text ?? (await readFile(join(ROOT, item.file ?? ""), "utf8"));

      const reply = await judge(template);

      expect(reply).toHaveProperty("selected");
      const selected = "selected" in reply ? reply.selected : [];
      expect(selected.map((link) => link.index)).toEqual(item.selected);
      expect(selected.map((link) => link.raw)).toEqual(
        item.selected.map((at) => item.candidates[at] ?? ""),
      );
    });

    test("judges the 63 cases and their 102 candidates", () => {
      expect(judgement.cases).toHaveLength(63);
      expect(judgement.cases.flatMap((item) => item.candidates)).toHaveLength(
        102,
      );
    });
  });
}
