import { join } from "node:path";

import { REPO } from "./sandbox.ts";
import type { Implementation } from "./types.ts";

// The TypeScript CLI of this checkout, started the way `bun run task` starts it.
export const TS_BASELINE: Implementation = {
  name: "ts",
  argv: [
    process.execPath,
    "--no-env-file",
    "--config=/dev/null",
    join(REPO, "src/cli/task.ts"),
  ],
};

export const nativeImplementation = (binary: string): Implementation => ({
  name: "native",
  argv: [binary],
});
