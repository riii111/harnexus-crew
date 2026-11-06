import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import {
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  readRegularTextFile,
  readTextFileIfExists,
  removeFile,
  writeFileAtomic,
} from "./fs.boundary.ts";

let dir: string;

beforeAll(async () => {
  dir = await mkdtemp(join(tmpdir(), "harnexus-fs-"));
});

afterAll(async () => {
  await rm(dir, { recursive: true, force: true });
});

describe("readTextFileIfExists", () => {
  test("returns null for a missing file", async () => {
    const read = await readTextFileIfExists(join(dir, "missing.json"));

    expect(read.isOk() && read.value).toBeNull();
  });

  test("returns an error for a path that cannot be read", async () => {
    const read = await readTextFileIfExists(dir);

    expect(read.isErr() && read.error._tag).toBe("FileReadFailed");
  });
});

describe("readRegularTextFile", () => {
  beforeAll(async () => {
    const made = Bun.spawnSync(["mkfifo", join(dir, "fifo")]);
    expect(made.exitCode).toBe(0);
    expect((await stat(join(dir, "fifo"))).isFIFO()).toBe(true);
  });

  test("returns the text of a regular file", async () => {
    await writeFile(join(dir, "note.md"), "text");

    const read = await readRegularTextFile(join(dir, "note.md"));

    expect(read.isOk() && read.value).toBe("text");
  });

  test.each([
    { name: "a missing file", path: () => join(dir, "missing.md") },
    { name: "a FIFO", path: () => join(dir, "fifo") },
  ])("returns an error without waiting for $name", async ({ path }) => {
    const read = await readRegularTextFile(path());

    expect(read.isErr() && read.error._tag).toBe("FileReadFailed");
  });
});

describe("writeFileAtomic", () => {
  test("replaces the content and leaves no temporary file", async () => {
    const target = join(dir, "atomic", "state.json");
    await mkdir(join(dir, "atomic"));
    await writeFile(target, "old");

    const written = await writeFileAtomic(target, "new");

    expect(written.isOk()).toBe(true);
    expect(await readFile(target, "utf8")).toBe("new");
    expect((await stat(target)).mode & 0o777).toBe(0o600);
    expect(await readdir(join(dir, "atomic"))).toEqual(["state.json"]);
  });

  test("returns an error when the directory is missing", async () => {
    const written = await writeFileAtomic(join(dir, "absent", "x.json"), "new");

    expect(written.isErr() && written.error._tag).toBe("FileWriteFailed");
  });

  test("keeps the target and removes the temporary file when the rename fails", async () => {
    const parent = join(dir, "rename-fails");
    const target = join(parent, "state.json");
    await mkdir(join(target, "occupied"), { recursive: true });

    const written = await writeFileAtomic(target, "new");

    expect(written.isErr() && written.error._tag).toBe("FileWriteFailed");
    expect(await readdir(parent)).toEqual(["state.json"]);
    expect(await readdir(target)).toEqual(["occupied"]);
  });
});

// The lock comes from macOS's O_EXLOCK, which other systems do not have.

describe("removeFile", () => {
  test("treats a missing file as removed", async () => {
    const removed = await removeFile(join(dir, "never-created"));

    expect(removed.isOk()).toBe(true);
  });

  test("reports a file that cannot be removed", async () => {
    await mkdir(join(dir, "busy", "inner"), { recursive: true });

    const removed = await removeFile(join(dir, "busy"));

    expect(removed.isErr() && removed.error._tag).toBe("FileRemoveFailed");
  });
});
