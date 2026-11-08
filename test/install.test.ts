import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const ROOT = join(import.meta.dir, "..");
const SCRIPT = join(ROOT, "scripts/install.sh");
const BUN_DIR = dirname(process.execPath);

const cleanups: string[] = [];

afterEach(async () => {
  for (const path of cleanups.splice(0))
    await rm(path, { recursive: true, force: true });
});

const scratch = async () => {
  const dir = await mkdtemp(join(tmpdir(), "harnexus-crew-install-test-"));
  cleanups.push(dir);
  return dir;
};

const run = (args: readonly string[], env: Record<string, string> = {}) => {
  const ran = Bun.spawnSync(["bash", SCRIPT, ...args], {
    env: {
      PATH: `${BUN_DIR}:/usr/bin:/bin`,
      HOME: "/nonexistent",
      XDG_CONFIG_HOME: "/nonexistent/config",
      ...env,
    },
    stdout: "pipe",
    stderr: "pipe",
  });
  return {
    status: ran.exitCode,
    stdout: ran.stdout.toString(),
    stderr: ran.stderr.toString(),
  };
};

const usageLine = (program: string) => {
  const ran = Bun.spawnSync([program, "launch"], { stderr: "pipe" });
  return ran.stderr.toString().split("\n").at(-2);
};

describe("scripts/install.sh", () => {
  test("is valid bash", () => {
    expect(Bun.spawnSync(["bash", "-n", SCRIPT]).exitCode).toBe(0);
  });

  test.each([
    {
      name: "a relative prefix",
      args: ["--prefix", "bin"],
      message: "--prefix must be an absolute path",
    },
    {
      name: "a relative bun path",
      args: ["--prefix", "/tmp/x", "--bun", "./bun"],
      message: "--bun must be an absolute path",
    },
    {
      name: "a repository without a commit",
      args: ["--prefix", "/tmp/x", "--repo", ROOT],
      message: "--repo needs --rev",
    },
    { name: "an unknown option", args: ["--nope"], message: "usage:" },
  ])("rejects $name", ({ args, message }) => {
    const ran = run(args);

    expect(ran.status).toBe(2);
    expect(ran.stderr).toContain(message);
  });

  test(
    "installs the requested commit and keeps it when a later build fails",
    async () => {
      const prefix = join(await scratch(), "bin");
      const head = Bun.spawnSync(["git", "-C", ROOT, "rev-parse", "HEAD"])
        .stdout.toString()
        .trim();
      const installed = run([
        "--prefix",
        prefix,
        "--repo",
        ROOT,
        "--rev",
        head,
      ]);
      const before = await stat(join(prefix, "harnexus-crew"));
      const failed = run(["--prefix", prefix, "--rev", "0000000"]);
      const after = await stat(join(prefix, "harnexus-crew"));

      expect([installed.status, installed.stderr]).toEqual([0, ""]);
      expect(installed.stdout).toContain(`from ${head}`);
      expect(usageLine(join(prefix, "harnexus-crew"))).toBe(
        "harnexus-crew: --request is required",
      );
      expect([failed.status, failed.stderr]).toEqual([
        1,
        expect.stringContaining("commit 0000000 is not in"),
      ]);
      expect([after.ino, after.mtimeMs]).toEqual([before.ino, before.mtimeMs]);
    },
    { timeout: 180_000 },
  );
});
