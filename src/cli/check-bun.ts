import { join } from "node:path";

import { pinnedBunOf, unpinnedBun } from "../task/bun-pin.ts";

// A compiled taskctl carries the Bun that built it, so a Bun other than the pinned one is stopped at the build rather than when a chat calls it.
const manifest: unknown = await Bun.file(
  join(import.meta.dir, "../../package.json"),
).json();
const problem = unpinnedBun(pinnedBunOf(manifest), Bun.version);
if (problem !== null) {
  process.stderr.write(`check-bun: ${problem}\n`);
  process.exitCode = 1;
}
