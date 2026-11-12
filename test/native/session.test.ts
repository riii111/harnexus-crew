import { describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  cp,
  mkdir,
  readdir,
  readFile,
  rename,
  writeFile,
} from "node:fs/promises";
import { dirname, join } from "node:path";

import { nativeImplementation, TS_BASELINE } from "../compat/baseline.ts";
import { startBridge } from "../compat/bridge.ts";
import { ROOT_MARK } from "../compat/normalize.ts";
import {
  createSandbox,
  readCommands,
  REPO,
  runGit,
  type Sandbox,
  snapshotFiles,
} from "../compat/sandbox.ts";
import { type Case, CaseSchema, type Implementation } from "../compat/types.ts";

const binary = process.env["HARNEXUS_CREW_NATIVE"];

type Ran = { code: number | null; stdout: string; stderr: string };

// A run as observed: the standard output is JSON where it parses.
type Seen = { code: number | null; stdout: unknown; stderr: string };

type Bridge = Awaited<ReturnType<typeof startBridge>>;

type Rig = {
  sandbox: Sandbox;
  bridge: Bridge | undefined;
  // Runs the CLI to its end.
  run: (argv: string[]) => Promise<Ran>;
  // Starts the CLI and leaves it running.
  start: (argv: string[]) => { kill: () => void; ended: Promise<Ran> };
};

const RUN_TIMEOUT_MS = 30_000;

const spawnCli = (
  implementation: Implementation,
  argv: string[],
  sandbox: Sandbox,
) => {
  const [file, ...prefix] = implementation.argv;
  if (file === undefined) throw new Error("implementation has no command");
  const child = spawn(file, [...prefix, ...argv], {
    cwd: sandbox.cwd,
    env: sandbox.env,
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk: string) => {
    stdout += chunk;
  });
  child.stderr.on("data", (chunk: string) => {
    stderr += chunk;
  });
  child.stdin.on("error", () => {});
  child.stdin.end();
  const timer = setTimeout(() => child.kill("SIGKILL"), RUN_TIMEOUT_MS);
  const ended = new Promise<Ran>((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr });
    });
  });
  return { kill: () => child.kill("SIGKILL"), ended };
};

// The scenario's sandbox: a case's files, repositories, shims and bridge plan, with the commands run by hand.
const withRig = async <T>(
  implementation: Implementation,
  fields: Partial<Case> & { name: string },
  body: (rig: Rig) => Promise<T>,
) => {
  const spec = CaseSchema.parse({
    owner: "MB09",
    status: "active",
    kind: "command",
    argv: [],
    ...fields,
  });
  const sandbox = await createSandbox(spec);
  const bridge =
    spec.bridge === undefined
      ? undefined
      : await startBridge(
          sandbox.bridgeSocket,
          JSON.parse(sandbox.expand(JSON.stringify(spec.bridge))),
        );
  try {
    const rig: Rig = {
      sandbox,
      bridge,
      run: (argv) => spawnCli(implementation, argv, sandbox).ended,
      start: (argv) => spawnCli(implementation, argv, sandbox),
    };
    const result = await body(rig);
    return {
      result,
      root: sandbox.root,
      requests: bridge?.requests ?? [],
      commands: await readCommands(sandbox.root),
      files: await snapshotFiles(sandbox.root, spec.snapshot),
    };
  } finally {
    await bridge?.stop();
    await sandbox.cleanup();
  }
};

const parsedOrText = (text: string): unknown => {
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
};

// What a run did, with JSON compared by meaning and the root named alike.
const observed = (done: Awaited<ReturnType<typeof withRig>>) => {
  const plain = JSON.parse(
    JSON.stringify(done).replaceAll(done.root, ROOT_MARK),
  ) as typeof done;
  const readable = (value: unknown, key = ""): unknown =>
    Array.isArray(value)
      ? value.map((item) => readable(item, key))
      : typeof value === "object" && value !== null
        ? Object.fromEntries(
            Object.entries(value).map(([name, item]) => [
              name,
              readable(item, name),
            ]),
          )
        : typeof value === "string" && key === "stdout"
          ? parsedOrText(value)
          : value;
  return {
    result: readable(plain.result),
    requests: plain.requests.map(parsedOrText),
    commands: plain.commands,
    files: Object.fromEntries(
      Object.entries(plain.files).map(([path, content]) => [
        path,
        path.endsWith(".json") ? parsedOrText(content) : content,
      ]),
    ),
  };
};

const SKILLS = { skills: "test/fixtures/task-skills" };
const CONFIG = {
  "config/harnexus/task.json": JSON.stringify({
    templates: {
      worker: "{{root}}/skills/task-session-launch/references/worker.md",
      reviewer: "{{root}}/skills/task-review-cycle/references/reviewer.md",
    },
  }),
};
const ENV = { HARNEXUS_CALL_SOCKET: "{{bridge}}", CODEX_THREAD_ID: "w1" };
const CAPS = {
  match: { query: "capabilities" },
  answer: {
    version: 1,
    outcome: "done",
    operations: [
      "list_projects",
      "create_thread",
      "send_message_to_thread",
      "name_thread",
    ],
  },
};
const answer = (tool: string, reply: Record<string, unknown>) => ({
  match: { tool },
  answer: { version: 1, ...reply },
});
const LIST = answer("list_projects", {
  outcome: "done",
  result: {
    projects: [{ projectId: "p-review", path: "{{home}}/review-home" }],
  },
});

const LAUNCH_REQUEST = {
  taskId: "TR1",
  documentRefs: ["https://example.com/task"],
  completionTarget: "draft_pr",
  projectId: "project",
};
const REPO_PATH = "{{home}}/.codex/worktrees/ab12/repo";
const REVIEW_REQUEST = {
  taskId: "TR1",
  workerAI: "Codex",
  projectId: "project",
  checkout: REPO_PATH,
  baseBranch: "base",
  documentRefs: ["https://example.com/task"],
  prUrl: null,
};
const REPOSITORY = [
  ["init", "-q", REPO_PATH],
  ["-C", REPO_PATH, "commit", "--allow-empty", "-qm", "test: initial"],
  ["-C", REPO_PATH, "branch", "base"],
  ["-C", REPO_PATH, "commit", "--allow-empty", "-qm", "test: candidate 1"],
];

const launchFields = (bridge: Case["bridge"]) => ({
  env: ENV,
  seed: SKILLS,
  bridge,
  files: { ...CONFIG, "work/launch.json": JSON.stringify(LAUNCH_REQUEST) },
});

const reviewFields = (bridge: Case["bridge"]) => ({
  env: ENV,
  seed: SKILLS,
  bridge,
  git: REPOSITORY,
  files: { ...CONFIG, "work/review.json": JSON.stringify(REVIEW_REQUEST) },
});

const commit = (rig: Rig, message: string, repository = REPO_PATH) =>
  runGit(rig.sandbox.root, [
    "-C",
    rig.sandbox.expand(repository),
    "commit",
    "--allow-empty",
    "-qm",
    message,
  ]);

const LAUNCH = ["launch", "--request", "launch.json"];
const REVIEW = ["review", "--request", "review.json"];

// Runs a scenario under the TypeScript build and the Native build alike, and returns what each did.
const both = async <T>(
  fields: Partial<Case> & { name: string },
  body: (rig: Rig) => Promise<T>,
) => {
  const ts = observed(await withRig(TS_BASELINE, fields, body));
  const native = observed(
    await withRig(nativeImplementation(binary ?? ""), fields, body),
  );
  return { ts, native };
};

const text = (value: unknown) => String(value);

if (binary !== undefined)
  describe("session commands under the Native build", () => {
    test("keep one worker per task, and show, rename and link it", async () => {
      const { ts, native } = await both(
        {
          name: "session-launch-flow",
          ...launchFields([
            CAPS,
            answer("create_thread", {
              outcome: "done",
              threadId: "w1",
              model: "claude-sonnet-5-5",
              effort: "high",
            }),
            CAPS,
            answer("name_thread", { outcome: "done" }),
          ]),
          commands: {
            "pr-wake": {
              stdout: '{"watched":"https://github.com/o/r/pull/3"}\n',
            },
          },
        },
        async ({ run }) => [
          await run(LAUNCH),
          await run(LAUNCH),
          await run(["state", "--request", "launch.json"]),
          await run(["name", "--pr", "https://github.com/o/r/pull/3"]),
        ],
      );

      expect(native).toEqual(ts);
      const steps = native.result as Seen[];
      expect(steps.map((step) => step.code)).toEqual([0, 0, 0, 0]);
      expect(steps[1]?.stdout).toMatchObject({ existing: "w1" });
      expect(steps[3]?.stdout).toMatchObject({
        title: "Impl TR1 PR#3",
        watched: "https://github.com/o/r/pull/3",
      });
      expect(
        native.requests.filter(
          (request) => (request as { tool?: string }).tool === "create_thread",
        ),
      ).toHaveLength(1);
    });

    test("hold a launch whose answer was lost until the user settles it", async () => {
      const { ts, native } = await both(
        {
          name: "session-launch-lost",
          ...launchFields([
            CAPS,
            answer("create_thread", {
              outcome: "unknown",
              error: "timed out",
            }),
          ]),
        },
        async ({ run }) => [
          await run(LAUNCH),
          await run(LAUNCH),
          await run([
            "resolve",
            "--request",
            "launch.json",
            "--sent",
            "--thread-id",
            "w9",
          ]),
          await run(LAUNCH),
        ],
      );

      expect(native).toEqual(ts);
      const steps = native.result as Seen[];
      expect(steps.map((step) => step.code)).toEqual([1, 1, 0, 0]);
      expect(text(steps[1]?.stderr)).toContain(
        "previous create_thread ended as unknown; never resend",
      );
      expect(steps[3]?.stdout).toMatchObject({ existing: "w9" });
      expect(native.requests).toHaveLength(2);
      expect(
        Object.keys(native.files).some((path) => path.endsWith("pending.json")),
      ).toBe(false);
    });

    test("start no second worker after a run that was sent and then released", async () => {
      const { ts, native } = await both(
        {
          name: "session-launch-not-sent",
          ...launchFields([
            CAPS,
            answer("create_thread", { outcome: "unknown", error: "lost" }),
            CAPS,
            answer("create_thread", {
              outcome: "done",
              threadId: "w2",
              model: "claude-sonnet-5-5",
              effort: "high",
            }),
          ]),
        },
        async ({ run }) => [
          await run(LAUNCH),
          await run(["resolve", "--request", "launch.json", "--not-sent"]),
          await run(LAUNCH),
        ],
      );

      expect(native).toEqual(ts);
      const steps = native.result as Seen[];
      expect(steps.map((step) => step.code)).toEqual([1, 0, 0]);
      expect(steps[1]?.stdout).toEqual({
        released: "create_thread",
        status: "unknown",
      });
      expect(steps[2]?.stdout).toMatchObject({ threadId: "w2" });
    });

    test("keep a reviewer, send each head once, and send a new head to the same reviewer", async () => {
      const { ts, native } = await both(
        {
          name: "session-review-flow",
          ...reviewFields([
            CAPS,
            LIST,
            CAPS,
            answer("create_thread", {
              outcome: "done",
              threadId: "r1",
              model: "gpt-6.1-sol",
              effort: "medium",
            }),
            CAPS,
            answer("send_message_to_thread", {
              outcome: "done",
              threadId: "r1",
            }),
          ]),
        },
        async (rig) => {
          const first = await rig.run(REVIEW);
          const again = await rig.run(REVIEW);
          commit(rig, "test: candidate 2");
          const second = await rig.run(REVIEW);
          const shown = await rig.run(["state", "--request", "review.json"]);
          return [first, again, second, shown];
        },
      );

      expect(native).toEqual(ts);
      const steps = native.result as Seen[];
      expect(steps.map((step) => step.code)).toEqual([0, 1, 0, 0]);
      expect(text(steps[1]?.stderr)).toContain(
        "was already sent to reviewer r1; wait for its result",
      );
      expect(steps[2]?.stdout).toMatchObject({
        tool: "send_message_to_thread",
        threadId: "r1",
      });
      expect(steps[3]?.stdout).toMatchObject({
        reviewerThreadId: "r1",
        workerThreadId: "w1",
        baseBranch: "base",
        pending: null,
      });
    });

    test("refuse a changed base branch until the base is updated", async () => {
      const { ts, native } = await both(
        {
          name: "session-review-base",
          ...reviewFields([
            CAPS,
            LIST,
            CAPS,
            answer("create_thread", { outcome: "done", threadId: "r1" }),
            CAPS,
            answer("send_message_to_thread", {
              outcome: "done",
              threadId: "r1",
            }),
          ]),
        },
        async (rig) => {
          await rig.run(REVIEW);
          runGit(rig.sandbox.root, [
            "-C",
            rig.sandbox.expand(REPO_PATH),
            "branch",
            "other",
          ]);
          commit(rig, "test: candidate 2");
          await writeFile(
            join(rig.sandbox.cwd, "review.json"),
            rig.sandbox.expand(
              JSON.stringify({ ...REVIEW_REQUEST, baseBranch: "other" }),
            ),
          );
          const refused = await rig.run(REVIEW);
          const updated = await rig.run([...REVIEW, "--update-base"]);
          return [refused, updated];
        },
      );

      expect(native).toEqual(ts);
      const steps = native.result as Seen[];
      expect(text(steps[0]?.stderr)).toContain(
        "baseBranch changed; use --update-base after integrating upstream",
      );
      expect(steps[1]?.code).toBe(0);
    });

    test("hold a review whose answer was lost, and send the head again once it is settled", async () => {
      const { ts, native } = await both(
        {
          name: "session-review-lost",
          ...reviewFields([
            CAPS,
            LIST,
            CAPS,
            answer("create_thread", {
              outcome: "unknown",
              threadId: "r1",
              error: "timed out",
            }),
            CAPS,
            answer("send_message_to_thread", {
              outcome: "done",
              threadId: "r1",
            }),
          ]),
        },
        async (rig) => {
          const lost = await rig.run(REVIEW);
          commit(rig, "test: candidate 2");
          const blocked = await rig.run(REVIEW);
          const resolved = await rig.run([
            "resolve",
            "--request",
            "review.json",
            "--sent",
          ]);
          commit(rig, "test: candidate 3");
          const resent = await rig.run(REVIEW);
          return [lost, blocked, resolved, resent];
        },
      );

      expect(native).toEqual(ts);
      const steps = native.result as Seen[];
      expect(steps.map((step) => step.code)).toEqual([1, 1, 0, 0]);
      expect(text(steps[1]?.stderr)).toContain(
        "previous create_thread ended as unknown; never resend",
      );
      expect(steps[3]?.stdout).toMatchObject({
        tool: "send_message_to_thread",
        threadId: "r1",
      });
    });

    test("keep a refused first turn apart until it is resolved as not sent", async () => {
      const { ts, native } = await both(
        {
          name: "session-review-refused",
          ...reviewFields([
            CAPS,
            LIST,
            CAPS,
            answer("create_thread", {
              outcome: "model_mismatch",
              threadId: "r1",
              expected: { model: "gpt-6.1-sol", effort: "medium" },
              actual: { model: "other", effort: "medium" },
            }),
            CAPS,
            LIST,
            CAPS,
            answer("create_thread", {
              outcome: "done",
              threadId: "r2",
              model: "gpt-6.1-sol",
              effort: "medium",
            }),
          ]),
        },
        async (rig) => {
          const refused = await rig.run(REVIEW);
          const blocked = await rig.run(REVIEW);
          const sent = await rig.run([
            "resolve",
            "--request",
            "review.json",
            "--sent",
          ]);
          const released = await rig.run([
            "resolve",
            "--request",
            "review.json",
            "--not-sent",
          ]);
          const shown = await rig.run(["state", "--request", "review.json"]);
          const again = await rig.run(REVIEW);
          return [refused, blocked, sent, released, shown, again];
        },
      );

      expect(native).toEqual(ts);
      const steps = native.result as Seen[];
      expect(steps.map((step) => step.code)).toEqual([1, 1, 1, 0, 0, 0]);
      expect(text(steps[2]?.stderr)).toContain(
        "a refused first turn never ran; use --not-sent",
      );
      expect(steps[4]?.stdout).toMatchObject({ refusedThreadIds: ["r1"] });
    });

    test("refuse a second run while the first is sending, and keep its record when that run dies", async () => {
      const { ts, native } = await both(
        {
          name: "session-launch-sending",
          // The bridge holds the first create, so that run is still sending.
          ...launchFields([
            CAPS,
            { match: { tool: "create_thread" }, answer: "silent" },
            CAPS,
            answer("create_thread", { outcome: "done", threadId: "w2" }),
          ]),
        },
        async ({ run, start, bridge }) => {
          const first = start(LAUNCH);
          const started = Date.now();
          while (
            !(bridge?.requests ?? []).some((line) =>
              line.includes('"create_thread"'),
            )
          ) {
            if (Date.now() - started > RUN_TIMEOUT_MS)
              throw new Error("the first run never sent");
            await Bun.sleep(5);
          }

          const beforeSecond = Date.now();
          const second = await run(LAUNCH);
          const secondTook = Date.now() - beforeSecond;
          // The run dies without an answer, so nothing releases its record.
          first.kill();
          await first.ended;
          const third = await run(LAUNCH);
          const released = await run([
            "resolve",
            "--request",
            "launch.json",
            "--not-sent",
          ]);
          const fourth = await run(LAUNCH);
          return { steps: [second, third, released, fourth], secondTook };
        },
      );

      const strip = (seen: typeof ts) => ({
        ...seen,
        result: {
          steps: (seen.result as { steps: unknown }).steps,
        },
      });
      expect(strip(native)).toEqual(strip(ts));
      for (const seen of [ts, native]) {
        const { steps, secondTook } = seen.result as {
          steps: Seen[];
          secondTook: number;
        };
        expect(steps.map((step) => step.code)).toEqual([1, 1, 0, 0]);
        expect(text(steps[0]?.stderr)).toContain(
          "previous create_thread ended as sending; never resend",
        );
        // Busy is answered at once, not after a wait on the first run.
        expect(secondTook).toBeLessThan(5_000);
        expect(steps[3]?.stdout).toMatchObject({ threadId: "w2" });
      }
    });

    test("send once when runs for the same task start together", async () => {
      const fields = {
        name: "session-launch-race",
        ...launchFields([
          CAPS,
          answer("create_thread", {
            outcome: "done",
            threadId: "w1",
            model: "claude-sonnet-5-5",
            effort: "high",
          }),
        ]),
      };
      for (const implementation of [
        TS_BASELINE,
        nativeImplementation(binary ?? ""),
      ]) {
        for (let attempt = 0; attempt < 5; attempt++) {
          const seen = await withRig(implementation, fields, async (rig) =>
            Promise.all(
              Array.from({ length: 4 }, () => rig.start(LAUNCH).ended),
            ),
          );
          const runs = seen.result;
          const created = seen.requests.filter((line) =>
            line.includes('"create_thread"'),
          );
          expect(created).toHaveLength(1);
          for (const ran of runs) {
            // A run is the one that sent, finds that worker, or is refused because another run is sending.
            expect(
              ran.code === 0
                ? true
                : /another harnexus-crew run is sending|previous create_thread ended as sending|changed the state/.test(
                    ran.stderr,
                  ),
            ).toBe(true);
          }

          expect(runs.some((ran) => ran.code === 0)).toBe(true);
          const kept = Object.entries(seen.files).filter(([path]) =>
            path.endsWith("/state.json"),
          );
          expect(kept).toHaveLength(1);
          expect(JSON.parse(kept[0]?.[1] ?? "{}")).toMatchObject({
            threadId: "w1",
          });
          expect(
            Object.keys(seen.files).some((path) =>
              path.endsWith("pending.json"),
            ),
          ).toBe(false);
        }
      }
    });
  });

// The state harnexus-task left in the app, moved to where this build keeps it and continued.
const FIXTURES = join(REPO, "test/fixtures/legacy-state/app");
const RECORDED_ROOT = "/tmp/taskctl-legacy";
const BASE = "af314261c610837f3606d61aa2dff1981debda94";
const HEAD_2 = "5455abba46706efa2a58a43a55b97e9d40eaa4ec";
// The checkout the recorded state names, under the sandbox's root.
const LEGACY_CHECKOUT = "{{root}}/app/codex/worktrees/ab12/checkout";

const keyDirectory = (key: string) =>
  createHash("sha256").update(key).digest("hex").slice(0, 16);

// Copies the recorded state under the sandbox's, naming the review directory by the key of the sandbox's own checkout.
const placeLegacyState = async (rig: Rig) => {
  const { root, expand } = rig.sandbox;
  const state = join(root, "state");
  await cp(join(FIXTURES, "state"), state, { recursive: true });
  await rename(join(state, "taskctl"), join(state, "harnexus-crew"));
  for (const file of await readdir(state, { recursive: true })) {
    if (!file.endsWith(".json")) continue;
    const path = join(state, file);
    const content = await readFile(path, "utf8");
    await writeFile(
      path,
      content
        .replaceAll("@ROOT@", root)
        .replaceAll("@SKILLS@", join(REPO, "test/fixtures/task-skills")),
    );
  }

  const recorded = `${RECORDED_ROOT}/app/codex/worktrees/ab12/checkout\nw1`;
  expect(keyDirectory(recorded)).toBe("d6efc365839bb319");
  const from = join(state, "harnexus-crew/review/d6efc365839bb319");
  const to = join(
    state,
    "harnexus-crew/review",
    keyDirectory(`${expand(LEGACY_CHECKOUT)}\nw1`),
  );
  await mkdir(dirname(to), { recursive: true });
  await rename(from, to);
};

if (binary !== undefined)
  describe("App state harnexus-task left, continued by the Native build", () => {
    const fields = {
      name: "session-legacy-app",
      env: { ...ENV, CODEX_HOME: "{{root}}/app/codex" },
      seed: SKILLS,
      git: [
        ["init", "-q", LEGACY_CHECKOUT],
        [
          "-C",
          LEGACY_CHECKOUT,
          "commit",
          "--allow-empty",
          "-qm",
          "test: initial",
        ],
        ["-C", LEGACY_CHECKOUT, "branch", "base"],
        [
          "-C",
          LEGACY_CHECKOUT,
          "commit",
          "--allow-empty",
          "-qm",
          "test: candidate 1",
        ],
        [
          "-C",
          LEGACY_CHECKOUT,
          "commit",
          "--allow-empty",
          "-qm",
          "test: candidate 2",
        ],
      ],
      bridge: [
        CAPS,
        answer("send_message_to_thread", { outcome: "done", threadId: "r1" }),
      ],
      files: {
        ...CONFIG,
        "work/launch.json": JSON.stringify(LAUNCH_REQUEST),
        "work/review.json": JSON.stringify({
          ...REVIEW_REQUEST,
          checkout: LEGACY_CHECKOUT,
        }),
      },
    };

    test("keeps the launched worker and its reviewer, resolving the re-review whose answer was lost", async () => {
      const { ts, native } = await both(fields, async (rig) => {
        await placeLegacyState(rig);
        const launched = await rig.run(LAUNCH);
        const held = await rig.run(REVIEW);
        const resolved = await rig.run([
          "resolve",
          "--request",
          "review.json",
          "--sent",
        ]);
        commit(rig, "test: candidate 3", LEGACY_CHECKOUT);
        const resent = await rig.run(REVIEW);
        const shown = await rig.run(["state", "--request", "review.json"]);
        return [launched, held, resolved, resent, shown];
      });

      expect(native).toEqual(ts);
      const steps = native.result as Seen[];
      expect(steps[0]?.stdout).toMatchObject({ existing: "w1" });
      expect(steps[1]?.code).toBe(1);
      expect(text(steps[1]?.stderr)).toContain(
        "previous send_message_to_thread ended as unknown; never resend",
      );
      expect(steps[2]?.stdout).toMatchObject({
        tool: "send_message_to_thread",
        threadId: "r1",
      });
      expect(steps[3]?.code).toBe(0);
      expect(steps[4]?.stdout).toMatchObject({
        reviewerThreadId: "r1",
        workerThreadId: "w1",
        base: BASE,
        pending: null,
        requested: { model: "gpt-6.1-sol", effort: "medium" },
      });
      expect(native.requests).toHaveLength(2);
      expect(JSON.stringify(native.requests[1])).toContain(`${BASE}...`);
    });

    test("sends the lost head again to the same reviewer once it is resolved as not sent", async () => {
      const { ts, native } = await both(fields, async (rig) => {
        await placeLegacyState(rig);
        const released = await rig.run([
          "resolve",
          "--request",
          "review.json",
          "--not-sent",
        ]);
        const resent = await rig.run(REVIEW);
        return [released, resent];
      });

      expect(native).toEqual(ts);
      const steps = native.result as Seen[];
      expect(steps[1]?.stdout).toMatchObject({ threadId: "r1" });
      expect(JSON.stringify(native.requests[1])).toContain(
        `${BASE}...${HEAD_2}`,
      );
    });
  });
