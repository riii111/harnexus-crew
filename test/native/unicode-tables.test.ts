import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

import { letterRanges, numberRanges } from "./unicode-tables.ts";

const TABLES = join(import.meta.dir, "../../native/text/unicode_tables.mbt");

const tableOf = (source: string, name: string) => {
  const body = new RegExp(
    `let ${name} : FixedArray\\[Int(?:32)?\\] = \\[([^\\]]*)\\]`,
  ).exec(source)?.[1];
  return (body?.match(/0x[0-9A-Fa-f]+/g) ?? []).map(Number);
};

test("the native Unicode tables are the letter and number classes of the pinned Bun", async () => {
  const source = await readFile(TABLES, "utf8");
  expect(tableOf(source, "letter_ranges")).toEqual(letterRanges());
  expect(tableOf(source, "number_ranges")).toEqual(numberRanges());
});
