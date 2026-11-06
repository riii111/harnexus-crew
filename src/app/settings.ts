export type TurnSettings = { model: string | null; effort: string | null };

const differs = (expected: string | null, actual: string | null) =>
  // A value the app leaves out cannot confirm what was asked, so it refuses the turn like a different one; a setting nobody asked for is not checked.
  expected !== null && expected !== actual;

// Says how the settings a turn ran with differ from those asked for, as the bridge words a refused first turn.
export const refusalOf = (expected: TurnSettings, actual: TurnSettings) =>
  (["model", "effort"] as const)
    .filter((key) => differs(expected[key], actual[key]))
    .map((key) =>
      actual[key] === null
        ? `did not say which ${key} (expected ${expected[key]})`
        : `asked for ${key} ${actual[key]} instead of ${expected[key]}`,
    )
    .join(" and ");
