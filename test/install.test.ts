import { afterEach, describe, expect, test } from "bun:test";
import {
  lstat,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  readlink,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
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

  test("leaves a harnexus-task that is not harnexus-crew alone, before building anything", async () => {
    const prefix = join(await scratch(), "bin");
    await mkdir(prefix);
    await writeFile(join(prefix, "harnexus-task"), "old");

    const ran = run(["--prefix", prefix, "--compat"]);

    expect([ran.status, ran.stderr]).toEqual([
      1,
      expect.stringContaining("is not harnexus-crew; leave it"),
    ]);
    expect(await readFile(join(prefix, "harnexus-task"), "utf8")).toBe("old");
    expect(await Bun.file(join(prefix, "harnexus-crew")).exists()).toBe(false);
  });

  test(
    "installs a commit with harnexus-task beside it, and keeps it when a later build fails",
    async () => {
      const prefix = join(await scratch(), "bin");
      await mkdir(prefix);
      await writeFile(join(prefix, "harnexus-task"), "old");
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
        "--replace-harnexus-task",
      ]);
      const before = await stat(join(prefix, "harnexus-crew"));
      const failed = run(["--prefix", prefix, "--rev", "0000000"]);
      const after = await stat(join(prefix, "harnexus-crew"));

      expect([installed.status, installed.stderr]).toEqual([0, ""]);
      expect(installed.stdout).toContain(`from ${head}`);
      expect(await readlink(join(prefix, "harnexus-task"))).toBe(
        "harnexus-crew",
      );
      expect(
        await readFile(join(prefix, "harnexus-task.pre-harnexus-crew"), "utf8"),
      ).toBe("old");
      expect(usageLine(join(prefix, "harnexus-crew"))).toBe(
        "harnexus-crew: --request is required",
      );
      expect(usageLine(join(prefix, "harnexus-task"))).toBe(
        "harnexus-task: --request is required",
      );
      expect([failed.status, failed.stderr]).toEqual([
        1,
        expect.stringContaining("commit 0000000 is not in"),
      ]);
      expect([after.ino, after.mtimeMs]).toEqual([before.ino, before.mtimeMs]);
      expect(
        (await lstat(join(prefix, "harnexus-task"))).isSymbolicLink(),
      ).toBe(true);
    },
    { timeout: 180_000 },
  );

  test(
    "puts back the earlier harnexus-crew and harnexus-task when the switch fails, and never installs a binary that cannot fill the templates",
    async () => {
      const root = await scratch();
      const prefix = join(root, "bin");
      await mkdir(prefix);
      const installed = run(["--prefix", prefix]);
      const before = await stat(join(prefix, "harnexus-crew"));
      await writeFile(join(prefix, "harnexus-task"), "old");
      const config = join(root, "config");
      await mkdir(join(config, "harnexus"), { recursive: true });
      await writeFile(join(root, "worker.md"), "[skill](missing/SKILL.md)\n");
      await writeFile(
        join(config, "harnexus/task.json"),
        JSON.stringify({ templates: { worker: join(root, "worker.md") } }),
      );

      const linkFailed = run(["--prefix", prefix, "--replace-harnexus-task"], {
        TASKCTL_INSTALL_FAULT: "link",
      });
      const afterLink = await stat(join(prefix, "harnexus-crew"));
      const unfilled = run(["--prefix", prefix], { XDG_CONFIG_HOME: config });
      const afterCheck = await stat(join(prefix, "harnexus-crew"));

      expect(installed.status).toBe(0);
      expect([linkFailed.status, linkFailed.stderr]).toEqual([
        1,
        expect.stringContaining(
          "the earlier harnexus-crew and harnexus-task were put back",
        ),
      ]);
      expect(await readFile(join(prefix, "harnexus-task"), "utf8")).toBe("old");
      expect(
        await Bun.file(
          join(prefix, "harnexus-task.pre-harnexus-crew"),
        ).exists(),
      ).toBe(false);
      expect(afterLink.ino).toBe(before.ino);
      expect([unfilled.status, unfilled.stderr]).toEqual([
        1,
        expect.stringContaining("cannot use the configured templates"),
      ]);
      expect(afterCheck.ino).toBe(before.ino);
      expect(
        (await readdir(prefix)).filter((name) => name.startsWith(".")),
      ).toEqual([]);
    },
    { timeout: 180_000 },
  );
});
