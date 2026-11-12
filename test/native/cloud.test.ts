import { describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { cp, mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

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

// Each scenario runs the TypeScript build and the Native build, several times each; the 5 second default is too short on a slow runner.
setDefaultTimeout(120_000);

type Ran = { code: number | null; stdout: string; stderr: string };

// A run as observed: the standard output is JSON where it parses.
type Seen = { code: number | null; stdout: unknown; stderr: string };

type Rig = {
  sandbox: Sandbox;
  // Runs the CLI to its end.
  run: (argv: string[]) => Promise<Ran>;
  // Starts the CLI and leaves it running.
  start: (argv: string[]) => { kill: () => void; ended: Promise<Ran> };
};

const RUN_TIMEOUT_MS = 60_000;

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

// The scenario's sandbox: a case's files, repositories and shims, with the commands run by hand.
const withRig = async <T>(
  implementation: Implementation,
  fields: Partial<Case> & { name: string },
  body: (rig: Rig) => Promise<T>,
) => {
  const spec = CaseSchema.parse({
    owner: "MB10",
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

// Times and process IDs differ from run to run, and nothing else is replaced.
const steady = (text: string) =>
  text
    .replace(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/g, "<TIME>")
    .replace(/\(pid \d+\)/g, "(pid <PID>)");

// What a run did, with JSON compared by meaning, the root named alike, and the times and process IDs set aside.
const observed = (done: Awaited<ReturnType<typeof withRig>>) => {
  const plain = JSON.parse(
    steady(JSON.stringify(done).replaceAll(done.root, ROOT_MARK)),
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

const REVIEWER = "01a18d52-e03a-74c1-a50e-4e697b47172b";
const OTHER = "01a18d52-e03a-74c1-a50e-4e697b47172c";
const BASE = "af314261c610837f3606d61aa2dff1981debda94";
const HEAD_1 = "a6bc63c9fd9d736a274586bb4a3989bc27297649";

const events = (threadId: string, answer: string) =>
  [
    { type: "thread.started", thread_id: threadId },
    { type: "turn.started" },
    {
      type: "item.completed",
      item: { id: "item_0", type: "agent_message", text: answer },
    },
    { type: "turn.completed", usage: { input_tokens: 1, output_tokens: 1 } },
  ]
    .map((event) => JSON.stringify(event))
    .join("\n");

type Plan = { out?: string; exit?: number; stderr?: string; sleep?: string };

// The stand-in for codex replays run n from these files, and records what it was given in the same directory.
const planned = (runs: Plan[]) =>
  Object.fromEntries(
    runs.flatMap((run, index) => {
      const n = index + 1;
      return [
        [`fake/out.${n}`, run.out ?? ""],
        [`fake/exit.${n}`, String(run.exit ?? 0)],
        ...(run.stderr === undefined ? [] : [[`fake/stderr.${n}`, run.stderr]]),
        ...(run.sleep === undefined ? [] : [[`fake/sleep.${n}`, run.sleep]]),
      ] as [string, string][];
    }),
  );

const REPO_PATH = "{{root}}/cloud/repo";
const REQUEST = {
  taskId: "example",
  workerAI: "Claude",
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
const FAKE = join(REPO, "test/native/mocks/fake-cli.sh");

const scenario = (
  name: string,
  runs: Plan[],
  options: {
    env?: Record<string, string>;
    files?: Record<string, string>;
    request?: Record<string, unknown>;
  } = {},
): Partial<Case> & { name: string } => ({
  name,
  env: {
    CLAUDE_CODE_REMOTE: "true",
    CLAUDE_CODE_SESSION_ID: "worker-session",
    HARNEXUS_CODEX_BIN: FAKE,
    FAKE_DIR: "{{root}}/fake",
    HOME: "{{root}}/cloud",
    ...options.env,
  },
  seed: { skills: "test/fixtures/task-skills" },
  git: REPOSITORY,
  // The recorded arguments, directories and prompts of the stand-in are compared with the state.
  snapshot: ["state", "fake", "work"],
  files: {
    "config/harnexus/task.json": JSON.stringify({
      templates: {
        reviewer: "{{root}}/skills/task-review-cycle/references/reviewer.md",
      },
    }),
    "work/review.json": JSON.stringify(options.request ?? REQUEST),
    "work/ask.md": "B1 はまだ残っていますか",
    ...planned(runs),
    ...options.files,
  },
});

// A process that has ended, whose ID no run is using.
const DEAD_PID = Bun.spawnSync(["true"]).pid;

const REVIEW = ["review", "--request", "review.json"];
const ASK = [...REVIEW, "--ask", "ask.md"];
const TIMED = {
  HARNEXUS_REVIEW_TIMEOUT_MS: "400",
  HARNEXUS_REVIEW_KILL_GRACE_MS: "400",
};

const commit = (rig: Rig, message: string) =>
  runGit(rig.sandbox.root, [
    "-C",
    rig.sandbox.expand(REPO_PATH),
    "commit",
    "--allow-empty",
    "-qm",
    message,
  ]);

const stateDirectories = async (rig: Rig) => {
  const base = join(rig.sandbox.root, "state/harnexus-crew/cloud-review");
  return (await readdir(base).catch(() => [] as string[])).map((name) =>
    join(base, name),
  );
};

// Waits until a run holds the session's lock.
const lockHeld = async (rig: Rig) => {
  for (let tries = 0; tries < 400; tries++) {
    for (const directory of await stateDirectories(rig))
      if (await Bun.file(join(directory, "lock.json")).exists())
        return directory;
    await Bun.sleep(25);
  }

  throw new Error("no run took the lock");
};

const stateOf = async (stdout: unknown) => {
  const path = (stdout as { state: string }).state;
  return { path, state: JSON.parse(await readFile(path, "utf8")) };
};

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

const codes = (result: unknown) => (result as Seen[]).map((step) => step.code);

const text = (value: unknown) => String(value);

if (binary !== undefined)
  describe("cloud reviews under the Native build", () => {
    test("review the first head, resume the reviewer on a new one, and refuse a head already judged", async () => {
      const { ts, native } = await both(
        scenario("cloud-review-flow", [
          { out: events(REVIEWER, "判定: 修正必要\n対象: …") },
          { out: events(REVIEWER, "判定: LGTM") },
        ]),
        async (rig) => {
          const first = await rig.run(REVIEW);
          const again = await rig.run(REVIEW);
          commit(rig, "test: candidate 2");
          const second = await rig.run(REVIEW);
          const third = await rig.run(REVIEW);
          return [first, again, second, third];
        },
      );

      expect(native).toEqual(ts);
      const steps = native.result as Seen[];
      expect(codes(steps)).toEqual([0, 1, 0, 1]);
      expect(steps[0]?.stdout).toMatchObject({
        status: "completed",
        verdict: "修正必要",
        base: BASE,
        head: HEAD_1,
        reviewer: REVIEWER,
      });
      expect(text(steps[1]?.stderr)).toContain(
        `head ${HEAD_1} was already reviewed by ${REVIEWER}; commit a fix before asking again`,
      );
      expect(steps[2]?.stdout).toMatchObject({
        verdict: "LGTM",
        base: BASE,
        reviewer: REVIEWER,
      });
      const argv = (n: number) => native.files[`fake/args.${n}`];
      expect(argv(1)).toContain("--sandbox\nread-only");
      expect(argv(2)).toContain(`resume\n${REVIEWER}`);
      expect(native.files["fake/count"]).toBe("2\n");
    });

    test("send a head again when the reviewer could not judge it, or gave no verdict", async () => {
      const { ts, native } = await both(
        scenario("cloud-review-unjudged", [
          { out: events(REVIEWER, "判定: 判定保留") },
          { out: events(REVIEWER, "指摘は以上です") },
          { out: events(REVIEWER, "判定: LGTM") },
        ]),
        async (rig) => [
          await rig.run(REVIEW),
          await rig.run(REVIEW),
          await rig.run(REVIEW),
          await rig.run(REVIEW),
        ],
      );

      expect(native).toEqual(ts);
      expect(codes(native.result)).toEqual([0, 0, 0, 1]);
      expect(native.files["fake/count"]).toBe("3\n");
    });

    test("count a head recorded before verdicts were kept as judged", async () => {
      const { ts, native } = await both(
        scenario("cloud-review-old-state", [
          { out: events(REVIEWER, "判定: 修正必要") },
          { out: events(REVIEWER, "判定: LGTM") },
        ]),
        async (rig) => {
          const first = await rig.run(REVIEW);
          const { path, state } = await stateOf(parsedOrText(first.stdout));
          delete state.verdict;
          await writeFile(path, JSON.stringify(state, null, 1));
          return [first, await rig.run(REVIEW)];
        },
      );

      expect(native).toEqual(ts);
      expect(codes(native.result)).toEqual([0, 1]);
      expect(native.files["fake/count"]).toBe("1\n");
    });

    test("leave nothing pending after a run that reviewed nothing, and keep the reviewer", async () => {
      const { ts, native } = await both(
        scenario("cloud-review-failed-run", [
          { out: events(REVIEWER, "判定: 修正必要") },
          { exit: 1, stderr: "network down" },
          { out: events(OTHER, "判定: LGTM") },
        ]),
        async (rig) => {
          const first = await rig.run(REVIEW);
          commit(rig, "test: candidate 2");
          const failed = await rig.run(REVIEW);
          const retried = await rig.run(REVIEW);
          return [first, failed, retried];
        },
      );

      expect(native).toEqual(ts);
      const steps = native.result as Seen[];
      expect(codes(steps)).toEqual([0, 1, 0]);
      expect(text(steps[1]?.stderr)).toContain(
        "codex did not review (exit 1): network down",
      );
      // The third run resumed the kept reviewer, and takes the thread its events name.
      expect(steps[2]?.stdout).toMatchObject({ reviewer: OTHER });
      expect(native.files["fake/args.3"]).toContain(`resume\n${REVIEWER}`);
      expect(
        Object.keys(native.files).some((path) => path.endsWith("pending.json")),
      ).toBe(false);
    });

    test("start a new reviewer once the old one is gone from the machine", async () => {
      const { ts, native } = await both(
        scenario("cloud-review-reviewer-gone", [
          { out: events(REVIEWER, "判定: 修正必要") },
          {
            exit: 1,
            stderr: `ERROR: no rollout found for thread id ${REVIEWER}`,
          },
          { out: events(OTHER, "判定: LGTM") },
        ]),
        async (rig) => {
          const first = await rig.run(REVIEW);
          commit(rig, "test: candidate 2");
          const gone = await rig.run(REVIEW);
          const started = await rig.run(REVIEW);
          return [first, gone, started];
        },
      );

      expect(native).toEqual(ts);
      const steps = native.result as Seen[];
      expect(codes(steps)).toEqual([0, 1, 0]);
      expect(text(steps[1]?.stderr)).toContain(
        `reviewer ${REVIEWER} is gone from this machine; run review again to start a new reviewer`,
      );
      expect(steps[2]?.stdout).toMatchObject({ reviewer: OTHER });
      expect(native.files["fake/args.3"]).not.toContain("resume");
    });

    test("hold a review that was stopped until it is discarded, and send it again", async () => {
      const { ts, native } = await both(
        scenario(
          "cloud-review-stopped",
          [
            { out: events(REVIEWER, "判定: LGTM"), sleep: "5" },
            { out: events(REVIEWER, "判定: LGTM") },
          ],
          { env: TIMED },
        ),
        async (rig) => [
          await rig.run(REVIEW),
          await rig.run(REVIEW),
          await rig.run([...REVIEW, "--recover", "discard"]),
          await rig.run([...REVIEW, "--recover", "discard"]),
        ],
      );

      expect(native).toEqual(ts);
      const steps = native.result as Seen[];
      expect(codes(steps)).toEqual([1, 1, 0, 1]);
      expect(text(steps[0]?.stderr)).toContain("codex was stopped (timeout)");
      expect(text(steps[1]?.stderr)).toContain(
        `the review of head ${HEAD_1} did not report back`,
      );
      expect(text(steps[3]?.stderr)).toContain(
        "--recover applies only when a review is pending",
      );
      expect(native.files["fake/count"]).toBe("2\n");
    });

    test("stop a run whose output passes the limit", async () => {
      const bin = "{{root}}/loud.sh";
      const { ts, native } = await both(
        scenario("cloud-review-output-limit", [], {
          env: {
            HARNEXUS_CODEX_BIN: bin,
            HARNEXUS_REVIEW_KILL_GRACE_MS: "400",
          },
          files: {
            "loud.sh": `#!/bin/sh\ncat > /dev/null\nhead -c 17000000 /dev/zero | tr '\\0' 'x'\nsleep 5\n`,
          },
        }),
        async (rig) => {
          await Bun.spawn(["chmod", "755", join(rig.sandbox.root, "loud.sh")])
            .exited;
          return [await rig.run(REVIEW), await rig.run(REVIEW)];
        },
      );

      expect(native).toEqual(ts);
      expect(codes(native.result)).toEqual([1, 1]);
      expect(text((native.result as Seen[])[0]?.stderr)).toContain(
        "codex was stopped (output over the limit)",
      );
    });

    test("pass a question to the reviewer and answer with its reply, leaving the state as it was", async () => {
      const { ts, native } = await both(
        scenario("cloud-review-ask", [
          { out: events(REVIEWER, "判定: 修正必要") },
          { out: events(REVIEWER, "B1 は残っています。\n判定: LGTM") },
        ]),
        async (rig) => {
          const before = await rig.run(ASK);
          const first = await rig.run(REVIEW);
          const kept = JSON.parse(
            await readFile(
              (await stateOf(parsedOrText(first.stdout))).path,
              "utf8",
            ),
          );
          const asked = await rig.run(ASK);
          const after = JSON.parse(
            await readFile(
              (await stateOf(parsedOrText(first.stdout))).path,
              "utf8",
            ),
          );
          expect(after).toEqual(kept);
          return [before, first, asked];
        },
      );

      expect(native).toEqual(ts);
      const steps = native.result as Seen[];
      expect(codes(steps)).toEqual([1, 0, 0]);
      expect(text(steps[0]?.stderr)).toContain(
        "this task has no reviewer yet; run review first",
      );
      expect(steps[2]?.stdout).toMatchObject({
        status: "completed",
        kind: "reply",
        verdict: "LGTM",
        head: HEAD_1,
        reviewer: REVIEWER,
        answer: "B1 は残っています。\n判定: LGTM",
      });
      expect(native.files["fake/stdin.2"]).toBe("B1 はまだ残っていますか");
    });

    test("refuse a question with no text, with a missing file, and for a stopped run", async () => {
      const { ts, native } = await both(
        scenario(
          "cloud-review-ask-refused",
          [
            { out: events(REVIEWER, "判定: 修正必要") },
            { out: events(REVIEWER, "x"), sleep: "5" },
            { exit: 2, stderr: "no model" },
          ],
          { env: TIMED, files: { "work/blank.md": " \n　\n" } },
        ),
        async (rig) => {
          await rig.run(REVIEW);
          return [
            await rig.run([...REVIEW, "--ask", "blank.md"]),
            await rig.run([...REVIEW, "--ask", "absent.md"]),
            await rig.run(ASK),
            await rig.run(ASK),
          ];
        },
      );

      expect(native).toEqual(ts);
      const steps = native.result as Seen[];
      expect(codes(steps)).toEqual([1, 1, 1, 1]);
      expect(text(steps[0]?.stderr)).toContain("the --ask file is empty");
      expect(text(steps[1]?.stderr)).toContain("cannot read absent.md");
      expect(text(steps[2]?.stderr)).toContain(
        `codex was stopped (timeout) in reviewer ${REVIEWER}; it may have answered`,
      );
      expect(text(steps[3]?.stderr)).toContain(
        `reviewer ${REVIEWER} did not answer (exit 2): no model`,
      );
    });

    test("refuse a second run while one holds the session, and take over a dead run's session", async () => {
      const { ts, native } = await both(
        scenario("cloud-review-lock", [
          { out: events(REVIEWER, "判定: LGTM"), sleep: "2" },
          { out: events(REVIEWER, "判定: 修正必要") },
        ]),
        async (rig) => {
          const holder = rig.start(REVIEW);
          const directory = await lockHeld(rig);
          const refused = await rig.run(REVIEW);
          const refusedAsk = await rig.run(ASK);
          const finished = await holder.ended;
          // A run that died leaves its lock, which the next run takes over.
          await writeFile(
            join(directory, "lock.json"),
            JSON.stringify({ pid: DEAD_PID, token: "gone", startedAt: "x" }),
          );
          commit(rig, "test: candidate 2");
          const taken = await rig.run(REVIEW);
          const lock = await Bun.file(join(directory, "lock.json")).exists();
          return [refused, refusedAsk, finished, taken, { lock }];
        },
      );

      expect(native).toEqual(ts);
      const steps = native.result as (Seen | { lock: boolean })[];
      expect(codes(steps.slice(0, 4))).toEqual([1, 1, 0, 0]);
      expect(text((steps[0] as Seen).stderr)).toContain(
        "another review (pid <PID>) is using this session",
      );
      expect(steps[4]).toEqual({ lock: false });
    });

    test("refuse to take over a session while a takeover died half way", async () => {
      const { ts, native } = await both(
        scenario("cloud-review-takeover-died", [
          { out: events(REVIEWER, "判定: LGTM") },
        ]),
        async (rig) => {
          const first = await rig.run(REVIEW);
          const [directory] = await stateDirectories(rig);
          if (directory === undefined) throw new Error("no session");
          await writeFile(
            join(directory, "lock.json"),
            JSON.stringify({ pid: DEAD_PID, token: "gone", startedAt: "x" }),
          );
          await writeFile(
            join(directory, "lock.json.reap"),
            JSON.stringify({ pid: DEAD_PID }),
          );
          commit(rig, "test: candidate 2");
          return [first, await rig.run(REVIEW)];
        },
      );

      expect(native).toEqual(ts);
      expect(codes(native.result)).toEqual([0, 1]);
      expect(text((native.result as Seen[])[1]?.stderr)).toContain(
        "a run that was taking over this session died before it finished",
      );
    });
  });

// Paths in the recorded state read @ROOT@, and directories keyed by a path are moved to the key of the test's own root.
const FIXTURE = join(REPO, "test/fixtures/legacy-state/cloud/state/taskctl");

const placeLegacyState = async (rig: Rig) => {
  const root = rig.sandbox.root;
  const state = join(root, "state/harnexus-crew/cloud-review");
  await mkdir(state, { recursive: true });
  const keyed = [
    { recorded: "3e52769db5ac05f8", task: "judged" },
    { recorded: "470a1ab24e770f8c", task: "lost" },
  ];
  for (const { recorded, task } of keyed) {
    const target = join(
      state,
      createHash("sha256")
        .update(`${root}/cloud/repo\0${task}`)
        .digest("hex")
        .slice(0, 16),
    );
    await cp(join(FIXTURE, "cloud-review", recorded), target, {
      recursive: true,
    });
    for (const name of await readdir(target)) {
      const path = join(target, name);
      await writeFile(
        path,
        (await readFile(path, "utf8")).replaceAll("@ROOT@", root),
      );
    }
  }
};

const taskRequest = (task: string) => ({ ...REQUEST, taskId: task });

if (binary !== undefined)
  describe("cloud review state harnexus-task left, under the Native build", () => {
    test("ask the same reviewer and re-review a new head with it, from the recorded base", async () => {
      const { ts, native } = await both(
        scenario(
          "cloud-review-legacy-judged",
          [
            { out: events(REVIEWER, "B1 は残っています。") },
            { out: events(REVIEWER, "判定: LGTM") },
          ],
          {
            request: taskRequest("judged"),
            files: { "work/ask.md": "B1 はまだ残っていますか" },
          },
        ),
        async (rig) => {
          await placeLegacyState(rig);
          const asked = await rig.run(ASK);
          commit(rig, "test: fix B1");
          const reviewed = await rig.run(REVIEW);
          return [asked, reviewed];
        },
      );

      expect(native).toEqual(ts);
      const steps = native.result as Seen[];
      expect(codes(steps)).toEqual([0, 0]);
      expect(steps[0]?.stdout).toMatchObject({
        kind: "reply",
        head: HEAD_1,
        reviewer: REVIEWER,
        answer: "B1 は残っています。",
      });
      expect(steps[1]?.stdout).toMatchObject({
        verdict: "LGTM",
        base: BASE,
        reviewer: REVIEWER,
      });
      for (const n of [1, 2])
        expect(native.files[`fake/args.${n}`]).toContain(
          `exec\nresume\n${REVIEWER}\n`,
        );
    });

    test("hold the review whose result was unknown until it is discarded, then send it again", async () => {
      const { ts, native } = await both(
        scenario(
          "cloud-review-legacy-lost",
          [{ out: events(REVIEWER, "判定: 修正必要") }],
          { request: taskRequest("lost") },
        ),
        async (rig) => {
          await placeLegacyState(rig);
          const held = await rig.run(REVIEW);
          const recovered = await rig.run([...REVIEW, "--recover", "discard"]);
          return [held, recovered];
        },
      );

      expect(native).toEqual(ts);
      const steps = native.result as Seen[];
      expect(codes(steps)).toEqual([1, 0]);
      expect(text(steps[0]?.stderr)).toContain("--recover discard");
      expect(steps[1]?.stdout).toMatchObject({
        verdict: "修正必要",
        base: BASE,
        head: HEAD_1,
      });
      expect(native.files["fake/args.1"]).not.toContain("resume");
    });
  });
