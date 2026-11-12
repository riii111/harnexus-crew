// Runs the cases against the TypeScript baseline and a Native binary, and prints the differences as JSON.
// usage: bun test/compat/cli.ts --native BINARY [--case NAME] [--include-pending]
import { resolve } from "node:path";
import { parseArgs } from "node:util";

import { nativeImplementation, TS_BASELINE } from "./baseline.ts";
import { loadCases } from "./cases.ts";
import { compare } from "./compare.ts";
import { observe } from "./execute.ts";
import { normalize } from "./normalize.ts";

const { values } = parseArgs({
  options: {
    native: { type: "string" },
    case: { type: "string" },
    "include-pending": { type: "boolean" },
  },
  strict: true,
});
if (values.native === undefined) {
  process.stderr.write("compat: --native BINARY is required\n");
  process.exit(2);
}

const native = nativeImplementation(resolve(values.native));
const cases = (await loadCases()).filter(
  (spec) =>
    (values.case === undefined || spec.name === values.case) &&
    (spec.status === "active" || values["include-pending"] === true),
);
const report = [];
for (const spec of cases) {
  const baseline = await observe(TS_BASELINE, spec);
  const candidate = await observe(native, spec);
  const differences = compare(
    spec,
    normalize(baseline.observation, spec, baseline.root),
    normalize(candidate.observation, spec, candidate.root),
  );
  report.push({ case: spec.name, owner: spec.owner, differences });
}

process.stdout.write(`${JSON.stringify({ cases: report.length, report })}\n`);
process.exitCode = report.some((entry) => entry.differences.length > 0) ? 1 : 0;
