import { expect, test } from "bun:test";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "..");

// The compiled CLI carries the Bun that built it, so CI must build with the Bun that package.json pins.
test("CI sets up the Bun that package.json pins", async () => {
  const pkg = (await Bun.file(join(ROOT, "package.json")).json()) as {
    packageManager: string;
  };
  const ci = await Bun.file(join(ROOT, ".github/workflows/ci.yml")).text();
  const pinned = pkg.packageManager.replace(/^bun@/, "");

  expect(ci).toContain(`bun-version: ${pinned}\n`);
});
