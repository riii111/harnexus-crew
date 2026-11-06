import { describe, expect, test } from "bun:test";

import { runCommand } from "./process.boundary.ts";

describe("runCommand", () => {
  test("returns the exit status and output of a failing command", async () => {
    const ran = await runCommand("/bin/sh", ["-c", "echo no >&2; exit 3"], {});

    expect(ran.isOk() && ran.value).toEqual({
      status: 3,
      stdout: "",
      stderr: "no\n",
    });
  });

  test("stops a command that runs past the timeout", async () => {
    const ran = await runCommand("/bin/sleep", ["5"], {}, 50);

    expect(ran.isErr() && ran.error.message).toBe(
      "/bin/sleep was stopped after 50 ms",
    );
  });
});
