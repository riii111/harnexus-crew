import {
  chmod,
  cp,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import type { Case, Observation } from "./types.ts";

export const REPO = join(import.meta.dir, "../..");

export type Sandbox = {
  root: string;
  env: Record<string, string>;
  cwd: string;
  bridgeSocket: string;
  expand: (text: string) => string;
  cleanup: () => Promise<void>;
};

// Each run gets its own home, config, state and temporary directories, so two implementations never share state.
export const createSandbox = async (spec: Case): Promise<Sandbox> => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "hxc-")));
  const dirs = {
    home: join(root, "home"),
    config: join(root, "config"),
    state: join(root, "state"),
    tmp: join(root, "tmp"),
    work: join(root, "work"),
    bin: join(root, "bin"),
  };
  await Promise.all(
    Object.values(dirs).map((dir) => mkdir(dir, { recursive: true })),
  );
  const bridgeSocket = join(root, "bridge.sock");
  const expand = (text: string) =>
    text
      .replaceAll("{{root}}", root)
      .replaceAll("{{bridge}}", bridgeSocket)
      .replaceAll("{{home}}", dirs.home)
      .replaceAll("{{config}}", dirs.config)
      .replaceAll("{{state}}", dirs.state)
      .replaceAll("{{tmp}}", dirs.tmp)
      .replaceAll("{{work}}", dirs.work);
  for (const [target, source] of Object.entries(spec.seed))
    await cp(join(REPO, source), join(root, target), { recursive: true });
  for (const [path, text] of Object.entries(spec.files)) {
    const target = join(root, path);
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, expand(text));
  }

  await writeShims(dirs.bin, spec);
  const env: Record<string, string> = {
    // The shims come first, so a command the implementation starts by name is the recorded one.
    PATH: `${dirs.bin}:${dirname(process.execPath)}:/usr/bin:/bin`,
    HOME: dirs.home,
    XDG_CONFIG_HOME: dirs.config,
    XDG_STATE_HOME: dirs.state,
    TMPDIR: dirs.tmp,
  };
  for (const [key, value] of Object.entries(spec.env)) env[key] = expand(value);
  return {
    root,
    env,
    cwd: dirs.work,
    bridgeSocket,
    expand,
    cleanup: () => rm(root, { recursive: true, force: true }),
  };
};

// A shim records its name, arguments and stdin, then answers as planned; it is a shell wrapper around Bun so no file needs a script extension.
// A caller that never writes or closes the shim's stdin, as execFile leaves it, would hold the shim until the harness kills it, so stdin is taken once nothing has arrived for STDIN_IDLE_MS.
const SHIM_SCRIPT = `
import { appendFileSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
const STDIN_IDLE_MS = 300;
const [, , dir, name, ...argv] = process.argv;
const plan = JSON.parse(readFileSync(join(dir, "plan.json"), "utf8"))[name] ?? {};
const stdin = await new Promise((resolve) => {
  const chunks = [];
  let timer;
  const finish = () => {
    clearTimeout(timer);
    resolve(Buffer.concat(chunks).toString("utf8"));
  };
  const wait = () => {
    clearTimeout(timer);
    timer = setTimeout(finish, STDIN_IDLE_MS);
  };
  process.stdin.on("data", (chunk) => {
    chunks.push(chunk);
    wait();
  });
  process.stdin.on("end", finish);
  wait();
});
appendFileSync(join(dir, "..", "records.jsonl"), JSON.stringify({ name, argv, stdin }) + "\\n");
process.stdout.write(plan.stdout ?? "");
process.stderr.write(plan.stderr ?? "");
process.exit(plan.exit ?? 0);
`;

const writeShims = async (bin: string, spec: Case) => {
  await writeFile(join(bin, "plan.json"), JSON.stringify(spec.commands));
  await writeFile(join(bin, "shim.js"), SHIM_SCRIPT);
  for (const name of Object.keys(spec.commands)) {
    const path = join(bin, name);
    await writeFile(
      path,
      `#!/bin/sh\nexec '${process.execPath}' '${join(bin, "shim.js")}' '${bin}' '${name}' "$@"\n`,
    );
    await chmod(path, 0o755);
  }
};

export const readCommands = async (root: string) => {
  const text = await readFile(join(root, "records.jsonl"), "utf8").catch(
    () => "",
  );
  return text
    .split("\n")
    .filter((line) => line !== "")
    .map((line) => JSON.parse(line) as Observation["commands"][number]);
};

export const snapshotFiles = async (root: string, dirs: string[]) => {
  const files: Record<string, string> = {};
  const walk = async (relative: string) => {
    const entries = await readdir(join(root, relative), {
      withFileTypes: true,
    }).catch(() => []);
    for (const entry of entries) {
      const path = join(relative, entry.name);
      if (entry.isDirectory()) await walk(path);
      // Sockets and links are not state, so only regular files are read.
      else if (entry.isFile())
        files[path] = await readFile(join(root, path), "utf8");
    }
  };

  for (const dir of dirs) await walk(dir);
  return files;
};
