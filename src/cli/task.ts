import { basename } from "node:path";

import { runTask, TASK_DEPS } from "../task/cli.ts";
import { reportCrash } from "../task/crash.boundary.ts";

// One program serves both names: harnexus-task keeps old chats, skills and permission rules working, and its messages keep that name.
const name =
  basename(process.argv0) === "harnexus-task" ? "harnexus-task" : "taskctl";

const run = await reportCrash(
  () =>
    runTask(process.argv.slice(2), {
      ...TASK_DEPS,
      env: process.env,
      name,
    }),
  name,
);
process.stdout.write(run.stdout);
process.stderr.write(run.stderr);
// Set rather than exiting at once, so output to a pipe is flushed first.
process.exitCode = run.code;
