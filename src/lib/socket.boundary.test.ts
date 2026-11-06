import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { requestLine } from "./socket.boundary.ts";

let directory = "";

beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), "harnexus-socket-"));
});

afterEach(async () => {
  await rm(directory, { recursive: true, force: true });
});

describe("requestLine", () => {
  test("reports a missing socket with its code", async () => {
    const answer = await requestLine(join(directory, "none.sock"), "x", 1000);

    expect(answer.isErr() && answer.error.code).toBe("ENOENT");
  });
});
