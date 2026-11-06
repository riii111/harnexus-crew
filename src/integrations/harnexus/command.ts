import { join } from "node:path";
import { createInterface } from "node:readline";

import { Result } from "better-result";

import { parseOptions } from "../../lib/args.boundary.ts";
import { readTextFileIfExists } from "../../lib/fs.boundary.ts";
import { parseJson } from "../../lib/json.boundary.ts";
import { isObject } from "../../lib/object.ts";
import { fail, type TaskFailed } from "../../task/format.ts";
import { saveJson } from "../../task/records.ts";
import { type Env, homeOf, io, readJson } from "../../task/request.ts";
import { createAdapter, handOver } from "./adapter.ts";
import { exportLinks, importLinks } from "./cloud-links.ts";
import { createObservations, observationRoot } from "./observations.ts";
import { createReviewStore, reviewsDirectory } from "./review-store.ts";

export type CommandRun = { code: number; stdout: string; stderr: string };

const USAGE = (name: string) => `usage:
  ${name} adapter serve --id ADAPTER_ID
  ${name} adapter handover
  ${name} adapter export-links
  ${name} adapter import-links FILE
`;

const ADAPTER_ID = /^[A-Za-z0-9_.-]{1,64}$/;

const parts = (env: Env) =>
  reviewsDirectory(env).map((dir) => {
    const root = observationRoot(env);
    return {
      store: createReviewStore(dir, join(root, "locks")),
      observations: createObservations(root),
      locks: join(root, "locks"),
    };
  });

const printed = (
  result: Result<unknown, TaskFailed>,
  name: string,
): CommandRun =>
  result.isOk()
    ? { code: 0, stdout: `${JSON.stringify(result.value)}\n`, stderr: "" }
    : { code: 1, stdout: "", stderr: `${name}: ${result.error.message}\n` };

const journalOf = (path: string) =>
  Result.gen(async function* () {
    const text = (yield* Result.await(io(readTextFileIfExists(path)))) ?? "";
    return Result.ok(
      text
        .split("\n")
        .filter((line) => line.trim() !== "")
        .flatMap((line) => {
          const parsed = parseJson(line).unwrapOr(null);
          return isObject(parsed) ? [parsed] : [];
        }),
    );
  });

// Serves one bridge connection on stdin and stdout until the bridge closes it; every line it cannot use is logged to stderr, which the bridge discards.
const serve = async (env: Env, adapterId: string) => {
  const built = parts(env);
  if (built.isErr())
    return { code: 1, stdout: "", stderr: `${built.error.message}\n` };
  const adapter = createAdapter({
    adapterId,
    ...built.value,
    reviewHome: join(homeOf(env), "review-home"),
    send: (line) => {
      process.stdout.write(`${line}\n`);
    },
    log: (entry) => {
      process.stderr.write(
        `${JSON.stringify({ time: new Date().toISOString(), ...entry })}\n`,
      );
    },
  });
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  // Only lines still being handled are held, so a long-running adapter does not keep every line it has read.
  const running = new Set<Promise<void>>();
  for await (const line of lines) {
    const handled = adapter
      .receive(line)
      .finally(() => running.delete(handled));
    running.add(handled);
  }

  await Promise.all(running);
  return { code: 0, stdout: "", stderr: "" };
};

export const runAdapterCommand = async (
  argv: readonly string[],
  env: Env,
  name: string,
): Promise<CommandRun> => {
  const [command, ...rest] = argv;
  const usageError = (message: string) => ({
    code: 2,
    stdout: "",
    stderr: `${USAGE(name)}${name}: ${message}\n`,
  });
  if (command === undefined || command === "-h" || command === "--help")
    return command === undefined
      ? usageError("expected serve, handover, export-links or import-links")
      : { code: 0, stdout: USAGE(name), stderr: "" };
  if (command === "serve") {
    const parsed = parseOptions(rest, { id: { type: "string" } });
    if (parsed.isErr()) return usageError(parsed.error.message);
    const id = parsed.value.id;
    if (typeof id !== "string" || !ADAPTER_ID.test(id))
      return usageError("--id ADAPTER_ID is required: letters, digits, _ . -");
    return serve(env, id);
  }

  if (rest.length > (command === "import-links" ? 1 : 0))
    return usageError(`${command} takes no more arguments`);
  switch (command) {
    case "handover": {
      const built = parts(env);
      if (built.isErr()) return printed(fail(built.error.message), name);
      const { observations, store } = built.value;
      const journal = await journalOf(observations.journalPath);
      return printed(
        journal.isErr()
          ? journal
          : await handOver(observations, store, journal.value),
        name,
      );
    }

    case "export-links":
      return printed(await exportLinks(env), name);
    case "import-links": {
      const file = rest[0];
      if (file === undefined)
        return usageError("import-links needs the links file");
      const read = await readJson(file);
      return printed(
        read.isErr() ? read : await importLinks(env, read.value, saveJson),
        name,
      );
    }

    default:
      return usageError(`unknown adapter command ${command}`);
  }
};
