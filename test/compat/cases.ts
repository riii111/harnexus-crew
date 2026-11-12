import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

import { type Case, CaseSchema } from "./types.ts";

const CASES = join(import.meta.dir, "cases");

export const loadCases = async (): Promise<Case[]> => {
  const names = (await readdir(CASES)).filter((name) => name.endsWith(".json"));
  const cases: Case[] = [];
  for (const name of names.sort()) {
    const parsed = CaseSchema.parse(
      JSON.parse(await readFile(join(CASES, name), "utf8")),
    );
    if (`${parsed.name}.json` !== name)
      throw new Error(`${name} must be named after its case, ${parsed.name}`);
    cases.push(parsed);
  }

  return cases;
};
