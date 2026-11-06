import { basename } from "node:path";

import { runAdapterCommand } from "../integrations/harnexus/command.ts";
import { runTask, TASK_DEPS } from "../task/cli.ts";
import { reportCrash } from "../task/crash.boundary.ts";

// One program serves both names: harnexus-task keeps old chats, skills and permission rules working, and its messages keep that name.
const name =
  basename(process.argv0) === "harnexus-task" ? "harnexus-task" : "taskctl";

const [command, ...rest] = process.argv.slice(2);
// The harnexus adapter runs as long as its bridge keeps it, so it is apart from the task commands, which answer once.
const run = await reportCrash(
  () =>
    command === "adapter"
      ? runAdapterCommand(rest, process.env, name)
      : runTask(process.argv.slice(2), {
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
