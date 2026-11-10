import type { Result } from "better-result";

import { prepareDirectory } from "../../lib/fs.boundary.ts";
import { fail, type TaskFailed } from "../../task/format.ts";
import { io } from "../../task/request.ts";
import { acquire, release } from "../../task/run-lock.ts";

const RETRY_MS = 50;
const WAIT_MS = 30_000;

// Runs the work while holding a lock file that every taskctl process on the machine respects, waiting for one held by another; a lock left by a dead process is taken over.
export const withLock = async <T>(
  directory: string,
  name: string,
  work: () => Promise<Result<T, TaskFailed>>,
  waitMs = WAIT_MS,
): Promise<Result<T, TaskFailed>> => {
  const made = await io(prepareDirectory(directory));
  if (made.isErr()) return made;
  const path = `${directory}/${name}.lock`;
  const until = Date.now() + waitMs;
  for (;;) {
    const taken = await acquire(path, "harnexus-crew adapter");
    if (taken.isOk()) {
      const done = await work();
      await release(path, taken.value);
      return done;
    }

    if (Date.now() >= until)
      return fail(`${path} stayed locked: ${taken.error.message}`);
    await Bun.sleep(RETRY_MS);
  }
};
