import { describe, expect, test } from "bun:test";

import { pinnedBunOf, unpinnedBun } from "./bun-pin.ts";

describe("unpinnedBun", () => {
  test("accepts the pinned Bun", () => {
    expect(unpinnedBun("1.4.4", "1.4.4")).toBeNull();
  });

  test.each([
    {
      name: "an older Bun",
      pinned: "1.4.4",
      running: "1.3.5",
      expected:
        "Bun 1.3.5 runs this build, while harnexus-crew pins 1.4.4; install Bun 1.4.4 and run scripts/install.sh again",
    },
    {
      name: "a manifest without a pin",
      pinned: null,
      running: "1.4.4",
      expected:
        "Bun 1.4.4 runs this build, while package.json pins no Bun version",
    },
  ])("refuses $name", ({ pinned, running, expected }) => {
    expect(unpinnedBun(pinned, running)).toBe(expected);
  });
});

describe("pinnedBunOf", () => {
  test.each([
    {
      name: "a pinned Bun",
      manifest: { packageManager: "bun@1.4.4" },
      expected: "1.4.4",
    },
    {
      name: "a range",
      manifest: { packageManager: "bun@^1.4" },
      expected: null,
    },
    {
      name: "another manager",
      manifest: { packageManager: "npm@10.0.0" },
      expected: null,
    },
    { name: "no manager", manifest: {}, expected: null },
  ])("reads $name", ({ manifest, expected }) => {
    expect(pinnedBunOf(manifest)).toBe(expected);
  });
});
