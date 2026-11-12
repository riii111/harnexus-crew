import type { Case, CompareMode, Difference, Observation } from "./types.ts";

const DEFAULT_MODES = {
  command: { stdout: "json", stderr: "exact" },
  help: { stdout: "exact", stderr: "exact" },
  session: { stdout: "lines", stderr: "exact" },
  inherit: { stdout: "exact", stderr: "exact" },
} as const;

const parse = (text: string): { value: unknown } | undefined => {
  try {
    return { value: JSON.parse(text) };
  } catch {
    return undefined;
  }
};

// JSON compares by meaning, so member order does not matter; text that is not JSON on both sides compares as written.
const sameJson = (expected: string, actual: string) => {
  const a = parse(expected);
  const b = parse(actual);
  return a !== undefined && b !== undefined
    ? Bun.deepEquals(a.value, b.value, true)
    : expected === actual;
};

const lineList = (text: string) => text.split("\n");

const textDifferences = (
  field: string,
  mode: CompareMode,
  expected: string,
  actual: string,
): Difference[] => {
  if (mode === "exact")
    return expected === actual ? [] : [{ field, expected, actual }];
  if (mode === "json")
    return sameJson(expected, actual) ? [] : [{ field, expected, actual }];
  // Lines keep their boundaries: two lines are never equal to one line holding both.
  const a = lineList(expected);
  const b = lineList(actual);
  const differences: Difference[] = [];
  if (a.length !== b.length)
    differences.push({
      field: `${field}.lines`,
      expected: a.length,
      actual: b.length,
    });
  for (let at = 0; at < Math.min(a.length, b.length); at++) {
    if (!sameJson(a[at] ?? "", b[at] ?? ""))
      differences.push({
        field: `${field}[${at}]`,
        expected: a[at],
        actual: b[at],
      });
  }

  return differences;
};

const listDifferences = <T>(
  field: string,
  expected: T[],
  actual: T[],
  same: (a: T, b: T) => boolean,
): Difference[] => {
  const differences: Difference[] = [];
  if (expected.length !== actual.length)
    differences.push({
      field: `${field}.count`,
      expected: expected.length,
      actual: actual.length,
    });
  for (let at = 0; at < Math.min(expected.length, actual.length); at++) {
    const a = expected[at] as T;
    const b = actual[at] as T;
    if (!same(a, b))
      differences.push({ field: `${field}[${at}]`, expected: a, actual: b });
  }

  return differences;
};

const fileDifferences = (
  expected: Record<string, string>,
  actual: Record<string, string>,
): Difference[] => {
  const differences: Difference[] = [];
  const paths = new Set([...Object.keys(expected), ...Object.keys(actual)]);
  for (const path of [...paths].sort()) {
    const a = expected[path];
    const b = actual[path];
    const same =
      a !== undefined && b !== undefined
        ? path.endsWith(".json")
          ? sameJson(a, b)
          : a === b
        : false;
    if (!same)
      differences.push({ field: `files.${path}`, expected: a, actual: b });
  }

  return differences;
};

// The differences between what the baseline did and what another implementation did, empty when they agree.
export const compare = (
  spec: Case,
  expected: Observation,
  actual: Observation,
): Difference[] => {
  const defaults = DEFAULT_MODES[spec.kind];
  return [
    ...(expected.exitCode === actual.exitCode
      ? []
      : [
          {
            field: "exitCode",
            expected: expected.exitCode,
            actual: actual.exitCode,
          },
        ]),
    ...(expected.signal === actual.signal
      ? []
      : [
          { field: "signal", expected: expected.signal, actual: actual.signal },
        ]),
    ...textDifferences(
      "stdout",
      spec.compare.stdout ?? defaults.stdout,
      expected.stdout,
      actual.stdout,
    ),
    ...textDifferences(
      "stderr",
      spec.compare.stderr ?? defaults.stderr,
      expected.stderr,
      actual.stderr,
    ),
    ...listDifferences(
      "requests",
      expected.requests,
      actual.requests,
      sameJson,
    ),
    ...listDifferences("commands", expected.commands, actual.commands, (a, b) =>
      Bun.deepEquals(a, b, true),
    ),
    ...fileDifferences(expected.files, actual.files),
  ];
};
