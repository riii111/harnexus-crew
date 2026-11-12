import { afterAll, describe, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { nativeImplementation, TS_BASELINE } from "./baseline.ts";
import { loadCases } from "./cases.ts";
import { compare } from "./compare.ts";
import { observe } from "./execute.ts";
import { normalize } from "./normalize.ts";
import { type Case, CaseSchema, type Implementation } from "./types.ts";

// A stand-in implementation: it writes the state files, sends the requests, runs the command, prints and exits as its options say.
const STUB = `
import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { connect } from "node:net";
import { dirname, join } from "node:path";

const options = JSON.parse(process.argv[2]);
for (const [path, text] of Object.entries(options.state ?? {})) {
  const target = join(process.env.XDG_STATE_HOME, path);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, text);
}
for (const line of options.requests ?? []) {
  await new Promise((resolve) => {
    const socket = connect(process.env.HARNEXUS_CALL_SOCKET);
    socket.on("connect", () => socket.write(line + "\\n"));
    socket.on("data", () => {});
    socket.on("close", resolve);
    socket.on("error", resolve);
  });
}
if (options.command) spawnSync(options.command[0], options.command.slice(1), { input: "prompt" });
process.stdout.write(options.stdout ?? "");
process.stderr.write(options.stderr ?? "");
process.exit(options.exit ?? 0);
`;

const roots: string[] = [];

afterAll(async () => {
  for (const root of roots) await rm(root, { recursive: true, force: true });
});

const stubPath = async () => {
  const root = await mkdtemp(join(tmpdir(), "hxc-stub-"));
  roots.push(root);
  const path = join(root, "stub.ts");
  await writeFile(path, STUB);
  return path;
};

const stub = async (options: object): Promise<Implementation> => ({
  name: "stub",
  argv: [process.execPath, await stubPath(), JSON.stringify(options)],
});

const spec = (overrides: Partial<Case> = {}): Case =>
  CaseSchema.parse({
    name: "stub-case",
    owner: "MB01",
    status: "active",
    kind: "command",
    argv: [],
    env: { HARNEXUS_CALL_SOCKET: "{{bridge}}" },
    bridge: [{ answer: { outcome: "done" } }, { answer: { outcome: "done" } }],
    commands: { codex: { stdout: "ok\n" } },
    ...overrides,
  });

const differences = async (
  caseSpec: Case,
  expected: Implementation,
  actual: Implementation,
) => {
  const a = await observe(expected, caseSpec);
  const b = await observe(actual, caseSpec);
  return compare(
    caseSpec,
    normalize(a.observation, caseSpec, a.root),
    normalize(b.observation, caseSpec, b.root),
  );
};

const BASE = {
  stdout: '{"a":1,"b":[1,2]}\n',
  stderr: "note\n",
  exit: 0,
  state: { "taskctl/k1/state.json": '{"x":1}' },
  requests: ['{"tool":"create_thread"}'],
  command: ["codex", "review"],
};

describe("comparison harness", () => {
  test("two runs of the same behaviour agree", async () => {
    const one = await stub(BASE);
    expect(await differences(spec(), one, await stub(BASE))).toEqual([]);
  });

  test("JSON compares by meaning, not by member order", async () => {
    const reordered = { ...BASE, stdout: '{"b":[1,2],"a":1}\n' };
    expect(
      await differences(spec(), await stub(BASE), await stub(reordered)),
    ).toEqual([]);
  });

  test.each([
    {
      name: "stdout meaning",
      change: { stdout: '{"a":2,"b":[1,2]}\n' },
      field: "stdout",
    },
    { name: "stderr text", change: { stderr: "other\n" }, field: "stderr" },
    { name: "exit code", change: { exit: 3 }, field: "exitCode" },
    {
      name: "state content",
      change: { state: { "taskctl/k1/state.json": '{"x":2}' } },
      field: "files.state/taskctl/k1/state.json",
    },
    {
      name: "state key",
      change: { state: { "taskctl/k2/state.json": '{"x":1}' } },
      field: "files.state/taskctl/k1/state.json",
    },
    {
      name: "request body",
      change: { requests: ['{"tool":"send_message_to_thread"}'] },
      field: "requests[0]",
    },
    {
      name: "command arguments",
      change: { command: ["codex", "resume"] },
      field: "commands[0]",
    },
  ])("detects a different $name", async ({ change, field }) => {
    const found = await differences(
      spec(),
      await stub(BASE),
      await stub({ ...BASE, ...change }),
    );
    expect(found.map((difference) => difference.field)).toContain(field);
  });

  test("detects a request sent twice", async () => {
    const twice = { ...BASE, requests: [...BASE.requests, ...BASE.requests] };
    const found = await differences(
      spec(),
      await stub(BASE),
      await stub(twice),
    );
    expect(found).toContainEqual({
      field: "requests.count",
      expected: 1,
      actual: 2,
    });
  });

  test("a time placeholder hides the time but not a duplicate", async () => {
    const normalizing = spec({
      normalize: [
        {
          pattern: "\\d{4}-\\d{2}-\\d{2}T[\\d:.]+Z",
          with: "<TIME>",
          scopes: ["requests"],
        },
      ],
    });
    const at = (time: string) => ({
      ...BASE,
      requests: [`{"asked":"${time}"}`],
    });
    expect(
      await differences(
        normalizing,
        await stub(at("2026-11-13T01:02:03.000Z")),
        await stub(at("2026-11-13T09:09:09.999Z")),
      ),
    ).toEqual([]);
    const doubled = {
      ...BASE,
      requests: [
        `{"asked":"2026-11-13T09:09:09.999Z"}`,
        `{"asked":"2026-11-13T09:09:09.999Z"}`,
      ],
    };
    const found = await differences(
      normalizing,
      await stub(at("2026-11-13T01:02:03.000Z")),
      await stub(doubled),
    );
    expect(found.map((difference) => difference.field)).toContain(
      "requests.count",
    );
  });

  test("a replacement in file contents leaves state keys visible", async () => {
    const keyed = spec({
      normalize: [{ pattern: "k\\d", with: "K", scopes: ["files"] }],
    });
    const found = await differences(
      keyed,
      await stub(BASE),
      await stub({
        ...BASE,
        state: { "taskctl/k2/state.json": '{"x":1}' },
      }),
    );
    expect(found.map((difference) => difference.field).sort()).toEqual([
      "files.state/taskctl/k1/state.json",
      "files.state/taskctl/k2/state.json",
    ]);
  });

  test("lines keep their boundaries in a session", async () => {
    const session = spec({
      kind: "session",
      bridge: undefined,
      commands: {},
      steps: [],
    });
    const found = await differences(
      session,
      await stub({ stdout: '{"id":1}\n{"id":2}\n' }),
      await stub({ stdout: '{"id":1}{"id":2}\n' }),
    );
    expect(found.map((difference) => difference.field)).toContain(
      "stdout.lines",
    );
  });

  test("a session passes each stdin line to stdout in order", async () => {
    const session = spec({ kind: "session", bridge: undefined, commands: {} });
    const { observation } = await observe(
      { name: "echo", argv: ["/bin/cat"] },
      {
        ...session,
        steps: [{ send: '{"id":1}' }, { wait: 1 }, { send: '{"id":2}' }],
      },
    );
    expect(observation.stdout).toBe('{"id":1}\n{"id":2}\n');
    expect(observation.exitCode).toBe(0);
  });
});

const cases = await loadCases();

describe("cases on the TypeScript baseline", () => {
  test.each(cases)(
    "$name gives the same observation in two sandboxes",
    async (caseSpec) => {
      const first = await observe(TS_BASELINE, caseSpec);
      const second = await observe(TS_BASELINE, caseSpec);
      expect(
        compare(
          caseSpec,
          normalize(first.observation, caseSpec, first.root),
          normalize(second.observation, caseSpec, second.root),
        ),
      ).toEqual([]);
    },
  );
});

const nativeBinary = process.env["HARNEXUS_CREW_NATIVE"];

// The Native binary runs only where a build exists; CI builds it before this test.
if (nativeBinary !== undefined) {
  describe("the Native binary under the harness", () => {
    test("the Native binary runs under the harness and a different observation shows as a difference", async () => {
      const find = (name: string) => {
        const found = cases.find((item) => item.name === name);
        if (found === undefined) throw new Error(`${name} is missing`);
        return found;
      };

      const asked = find("help");
      const baseline = await observe(TS_BASELINE, asked);
      const native = await observe(
        nativeImplementation(nativeBinary),
        find("usage-unknown-subcommand"),
      );
      const fields = compare(
        asked,
        normalize(baseline.observation, asked, baseline.root),
        normalize(native.observation, asked, native.root),
      ).map((difference) => difference.field);
      expect(fields).toContain("exitCode");
      expect(fields).toContain("stdout");
    });
  });
}
