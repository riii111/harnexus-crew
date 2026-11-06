import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { callApp } from "./call.ts";

const cleanups: (() => Promise<unknown>)[] = [];

afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

// A bridge that answers each line it receives by the given rule, or not at all for null.
const bridge = async (answer: (line: Record<string, unknown>) => unknown) => {
  const dir = await mkdtemp(join(tmpdir(), "taskctl-call-"));
  cleanups.push(() => rm(dir, { recursive: true, force: true }));
  const path = join(dir, "call.sock");
  const lines: Record<string, unknown>[] = [];
  const server = createServer((socket) => {
    let data = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      data += chunk;
      if (!data.endsWith("\n")) return;
      const line = JSON.parse(data) as Record<string, unknown>;
      lines.push(line);
      const reply = answer(line);
      if (reply !== null) socket.end(`${JSON.stringify(reply)}\n`);
    });
  });
  await new Promise<void>((resolve) => server.listen(path, resolve));
  cleanups.push(() => new Promise((resolve) => server.close(resolve)));
  return { path, lines };
};

const offering =
  (operations: string[], answer: unknown) => (line: Record<string, unknown>) =>
    line.query === "capabilities"
      ? { version: 1, outcome: "done", operations }
      : answer;

const deps = (path: string, timeoutMs?: number) => ({
  env: { HARNEXUS_CALL_SOCKET: path },
  home: "/nonexistent",
  ...(timeoutMs === undefined ? {} : { timeoutMs }),
});

describe("callApp", () => {
  test("asks for protocol 1, then sends the call with it and answers without the version", async () => {
    const { path, lines } = await bridge(
      offering(["name_thread"], { version: 1, outcome: "done", result: {} }),
    );

    const answer = await callApp(deps(path), "w1", "name_thread", {
      name: "Impl TR1",
    });

    expect(answer).toEqual({ outcome: "done", result: {} });
    expect(lines).toEqual([
      { version: 1, query: "capabilities" },
      {
        version: 1,
        threadId: "w1",
        tool: "name_thread",
        arguments: { name: "Impl TR1" },
      },
    ]);
  });

  test("takes an older bridge's invalid answer as unsupported and sends it nothing more", async () => {
    const { path, lines } = await bridge(() => ({
      outcome: "invalid",
      message: "expected {threadId,tool,arguments}",
    }));

    const answer = await callApp(deps(path), "w1", "create_thread", {});

    expect(answer).toEqual({
      outcome: "unsupported",
      error:
        "the bridge does not offer call protocol 1; update harnexus and restart the app",
    });
    expect(lines).toHaveLength(1);
  });

  test("sends nothing for a tool the bridge does not offer", async () => {
    const { path, lines } = await bridge(offering(["create_thread"], null));

    const answer = await callApp(deps(path), "w1", "cloud_open", {});

    expect(answer).toEqual({
      outcome: "unsupported",
      error: "the bridge does not offer cloud_open",
    });
    expect(lines).toHaveLength(1);
  });

  test("reports a call sent without an answer in time as unknown", async () => {
    const { path } = await bridge(offering(["create_thread"], null));

    const answer = await callApp(deps(path, 50), "w1", "create_thread", {});

    expect(answer.outcome).toBe("unknown");
  });

  test.each([
    {
      name: "a missing socket",
      env: { HARNEXUS_CALL_SOCKET: "/nonexistent/call.sock" },
      error: "no bridge has opened the socket",
    },
    {
      name: "a socket turned off",
      env: { HARNEXUS_CALL_SOCKET: "off" },
      error: "the call socket is off",
    },
    {
      name: "a relative socket path",
      env: { HARNEXUS_CALL_SOCKET: "call.sock" },
      error: "HARNEXUS_CALL_SOCKET must be on, off or an absolute path",
    },
  ])("reports $name as not sent", async ({ env, error }) => {
    const answer = await callApp(
      { env, home: "/nonexistent" },
      "w1",
      "create_thread",
      {},
    );

    expect(answer.outcome).toBe("not_sent");
    expect(answer.error).toContain(error);
  });
});
