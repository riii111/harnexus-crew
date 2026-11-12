import { spawn } from "node:child_process";

import { startBridge } from "./bridge.ts";
import { createSandbox, readCommands, snapshotFiles } from "./sandbox.ts";
import type { Case, Implementation, Observation } from "./types.ts";

const RUN_TIMEOUT_MS = 30_000;

const waitFor = async (ready: () => boolean, what: string) => {
  const started = Date.now();
  while (!ready()) {
    if (Date.now() - started > RUN_TIMEOUT_MS)
      throw new Error(`timed out waiting for ${what}`);
    await Bun.sleep(5);
  }
};

// Runs one implementation on one case in a fresh sandbox and returns what it did, before any normalization.
export const observe = async (
  implementation: Implementation,
  spec: Case,
): Promise<{ observation: Observation; root: string }> => {
  const sandbox = await createSandbox(spec);
  const bridge =
    spec.bridge === undefined
      ? undefined
      : await startBridge(sandbox.bridgeSocket, spec.bridge);
  try {
    const [file, ...prefix] = implementation.argv;
    if (file === undefined) throw new Error("implementation has no command");
    const child = spawn(file, [...prefix, ...spec.argv], {
      cwd: sandbox.cwd,
      env: sandbox.env,
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let lines = 0;
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      stdout += chunk;
      lines = stdout.split("\n").length - 1;
    });
    child.stderr.on("data", (chunk: string) => {
      stderr += chunk;
    });
    child.stdin.on("error", () => {});
    const ended = new Promise<{ code: number | null; signal: string | null }>(
      (resolve, reject) => {
        child.once("error", reject);
        child.once("close", (code, signal) => {
          resolve({ code, signal });
        });
      },
    );
    const timer = setTimeout(() => child.kill("SIGKILL"), RUN_TIMEOUT_MS);
    if (spec.kind === "session") {
      for (const step of spec.steps) {
        if ("send" in step) child.stdin.write(`${step.send}\n`);
        else await waitFor(() => lines >= step.wait, `${step.wait} lines`);
      }
    } else child.stdin.write(spec.stdin);
    child.stdin.end();
    const { code, signal } = await ended;
    clearTimeout(timer);
    return {
      root: sandbox.root,
      observation: {
        exitCode: code,
        signal,
        stdout,
        stderr,
        requests: bridge?.requests ?? [],
        commands: await readCommands(sandbox.root),
        files: await snapshotFiles(sandbox.root, spec.snapshot),
      },
    };
  } finally {
    await bridge?.stop();
    await sandbox.cleanup();
  }
};
