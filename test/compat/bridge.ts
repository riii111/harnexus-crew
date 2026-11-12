import { createServer, type Server, type Socket } from "node:net";

import type { Case } from "./types.ts";

type Step = NonNullable<Case["bridge"]>[number];

const contains = (request: unknown, match: Record<string, unknown>) =>
  typeof request === "object" &&
  request !== null &&
  Object.entries(match).every(([key, value]) =>
    Bun.deepEquals((request as Record<string, unknown>)[key], value, true),
  );

const parse = (line: string): unknown => {
  try {
    return JSON.parse(line);
  } catch {
    return undefined;
  }
};

// A stand-in for the harnexus bridge: it records every connection and answers from the plan, once per step.
export const startBridge = async (path: string, steps: Step[]) => {
  const requests: string[] = [];
  const used = new Set<number>();
  const held: Socket[] = [];
  const answer = (socket: Socket, line: string) => {
    const request = parse(line);
    const index = steps.findIndex(
      (step, at) =>
        !used.has(at) &&
        (step.match === undefined || contains(request, step.match)),
    );
    const step = steps[index];
    if (step === undefined) {
      // An unplanned request is still recorded, and answered so that it shows as a difference rather than hanging.
      socket.end(
        `${JSON.stringify({ outcome: "invalid", message: "unplanned request" })}\n`,
      );
      return;
    }

    used.add(index);
    if (step.answer === "drop") socket.destroy();
    else if (step.answer === "silent") held.push(socket);
    else socket.end(`${JSON.stringify(step.answer)}\n`);
  };

  const server: Server = createServer((socket) => {
    let data = "";
    let line: string | undefined;
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      data += chunk;
      const end = data.indexOf("\n");
      if (line !== undefined || end < 0) return;
      line = data.slice(0, end);
      requests.push(line);
      answer(socket, line);
    });
    socket.on("close", () => {
      if (line === undefined) requests.push(data);
    });
    socket.on("error", () => {});
  });
  await new Promise<void>((resolve) => {
    server.listen(path, resolve);
  });
  return {
    requests,
    stop: () => {
      for (const socket of held) socket.destroy();
      return new Promise<void>((resolve) => {
        server.close(() => {
          resolve();
        });
      });
    },
  };
};
