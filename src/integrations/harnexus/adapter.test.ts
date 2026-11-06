import { afterEach, describe, expect, test } from "bun:test";
import {
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createAdapter, handOver } from "./adapter.ts";
import { createObservations } from "./observations.ts";
import { createReviewStore } from "./review-store.ts";
import {
  REVIEW_ASK_SENT,
  REVIEW_ASK_UNROUTED,
  reviewerAsk,
  reviewsIn,
  reviewText,
} from "./reviews.ts";
import { prompt, ran, reviewOutput } from "./testing/session-record.ts";

type Line = Record<string, unknown>;

const cleanups: (() => Promise<unknown>)[] = [];

afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

const SESSION = "session_01AbC";
const PARENT = "parent-chat";

const settle = () => new Promise((resolve) => setTimeout(resolve, 5));

// Records of a Cloud session in which the reviewer R1 judged heads in turn.
const judged = (head: string, reviewer = "R1") =>
  ran(
    `t-${head}-${reviewer}`,
    reviewOutput({ head, reviewer, answer: `判定: LGTM ${head}` }),
  );

const place = async () => {
  const root = await realpath(
    await mkdtemp(join(tmpdir(), "taskctl-adapter-")),
  );
  cleanups.push(() => rm(root, { recursive: true, force: true }));
  const reviews = join(root, "cloud-reviews");
  const observe = join(root, "observe");
  const reviewHome = join(root, "review-home");
  await mkdir(reviewHome);
  return { root, reviews, observe, reviewHome };
};

type Place = Awaited<ReturnType<typeof place>>;

// One bridge connection with the adapter: the lines the adapter sent, and the bridge's answers to its requests.
const connect = (
  at: Place,
  answer: (request: Line) => Line = () => ({ outcome: "done" }),
) => {
  const sent: Line[] = [];
  const store = createReviewStore(at.reviews, join(at.observe, "locks"));
  const observations = createObservations(at.observe);
  const adapter = createAdapter({
    adapterId: "taskctl",
    store,
    observations,
    locks: join(at.observe, "locks"),
    reviewHome: at.reviewHome,
    log: () => {},
    send: (raw) => {
      const line = JSON.parse(raw) as Line;
      sent.push(line);
      if (line.type === "request")
        setTimeout(() => {
          void adapter.receive(
            JSON.stringify({
              v: 1,
              type: "response",
              id: line.id,
              bridgeId: "b1",
              ...answer(line),
            }),
          );
        }, 1);
    },
  });
  const say = async (line: Line) => {
    await adapter.receive(JSON.stringify({ v: 1, ...line }));
    await settle();
  };

  const start = async (mode: "observe" | "write") => {
    await say({
      type: "hello",
      bridgeId: "b1",
      adapterId: "taskctl",
      mode,
      versions: [1],
    });
    await say({
      type: "ready",
      bridgeId: "b1",
      bindings: [],
      pending: [],
      conflicts: [],
    });
  };

  let events = 0;
  const records = async (fields: Line) => {
    events += 1;
    await say({
      type: "event",
      event: "session_records",
      eventId: `e${events}`,
      sessionId: SESSION,
      parentThreadId: PARENT,
      link: PARENT,
      shownBefore: null,
      ...fields,
    });
  };

  const requests = (op?: string) =>
    sent.filter(
      (line) => line.type === "request" && (op === undefined || line.op === op),
    );
  return { sent, say, start, records, requests, store, observations };
};

const journal = async (at: Place) =>
  (await readFile(join(at.observe, "journal.jsonl"), "utf8").catch(() => ""))
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as Line);

const reviewFiles = async (at: Place) =>
  (await readdir(at.reviews).catch(() => [] as string[])).sort();

describe("an observing adapter", () => {
  test("journals only the reviews after the link, writes nothing, and confirms each event once its position is kept", async () => {
    const at = await place();
    const bridge = connect(at);
    await bridge.start("observe");
    const before = [prompt("p0", "start"), ...judged("aaa1111")];

    await bridge.records({
      phase: "linked",
      linkedAt: "u-t-aaa1111-R1",
      records: before,
    });
    await bridge.records({
      phase: "continued",
      shownBefore: "u-t-aaa1111-R1",
      records: [...before, ...judged("bbb2222")],
    });

    const hello = bridge.sent.find((line) => line.type === "hello");
    expect(hello).toEqual({
      v: 1,
      type: "hello",
      adapterId: "taskctl",
      bindings: [],
    });
    expect(bridge.requests()).toEqual([]);
    expect(bridge.sent.filter((line) => line.type === "observed")).toEqual([
      { v: 1, type: "observed", eventId: "e1" },
      { v: 1, type: "observed", eventId: "e2" },
    ]);
    expect(
      (await journal(at))
        .filter((line) => line.kind === "observed_review")
        .map((line) => (line.review as Line).head),
    ).toEqual(["bbb2222"]);
    expect(await reviewFiles(at)).toEqual([]);
  });

  test("takes a session first seen continuing from what the app was last shown, and marks that base as estimated", async () => {
    const at = await place();
    const bridge = connect(at);
    await bridge.start("observe");

    await bridge.records({
      phase: "continued",
      shownBefore: "u-t-aaa1111-R1",
      records: [...judged("aaa1111"), ...judged("bbb2222")],
    });

    const lines = await journal(at);
    expect(
      lines.find((line) => line.kind === "baseline_estimated"),
    ).toMatchObject({ sessionId: SESSION, shownBefore: "u-t-aaa1111-R1" });
    expect(
      lines
        .filter((line) => line.kind === "observed_review")
        .map((line) => (line.review as Line).head),
    ).toEqual(["bbb2222"]);
    const position = JSON.parse(
      await readFile(join(at.observe, "sessions", `${SESSION}.json`), "utf8"),
    );
    expect(position.baseline).toMatchObject({
      uuid: "u-t-aaa1111-R1",
      estimated: true,
    });
  });

  test("takes a review made while it was stopped once after it restarts, and records a cursor it cannot find again", async () => {
    const at = await place();
    const first = connect(at);
    await first.start("observe");
    const linked = [...judged("aaa1111")];
    await first.records({
      phase: "linked",
      linkedAt: "u-t-aaa1111-R1",
      records: linked,
    });

    const second = connect(at);
    await second.start("observe");
    const later = [...linked, ...judged("bbb2222")];
    await second.records({
      phase: "continued",
      shownBefore: "u-t-aaa1111-R1",
      records: later,
    });
    await second.records({
      phase: "continued",
      shownBefore: "u-t-aaa1111-R1",
      records: later,
    });
    // Records cut to the newest still hold the cursor, so only the review after it is taken.
    await second.records({
      phase: "continued",
      shownBefore: null,
      records: [
        ...judged("aaa1111"),
        ...judged("bbb2222"),
        ...judged("ccc3333"),
      ].slice(2),
    });

    const lines = await journal(at);
    expect(
      lines
        .filter((line) => line.kind === "observed_review")
        .map((line) => (line.review as Line).head),
    ).toEqual(["bbb2222", "ccc3333"]);
    expect(lines.filter((line) => line.kind === "cursor_missing")).toHaveLength(
      0,
    );
    const position = JSON.parse(
      await readFile(join(at.observe, "sessions", `${SESSION}.json`), "utf8"),
    );
    expect(position.cursor).toBe("u-t-ccc3333-R1");
  });

  test("records a gap when the cursor's record is gone, without taking a review again", async () => {
    const at = await place();
    const bridge = connect(at);
    await bridge.start("observe");
    await bridge.records({ phase: "linked", linkedAt: null, records: [] });
    await bridge.records({
      phase: "continued",
      records: [prompt("p1", "x"), ...judged("aaa1111")],
    });

    // The same review read again under records of other ids, as when the session's earlier records are gone.
    const reread = ran(
      "other",
      reviewOutput({
        head: "aaa1111",
        reviewer: "R1",
        answer: "判定: LGTM aaa1111",
      }),
    );
    await bridge.records({
      phase: "continued",
      records: [...reread, prompt("p2", "y")],
    });

    const lines = await journal(at);
    expect(lines.filter((line) => line.kind === "cursor_missing")).toEqual([
      expect.objectContaining({ sessionId: SESSION, cursor: "u-t-aaa1111-R1" }),
    ]);
    expect(
      lines.filter((line) => line.kind === "observed_review"),
    ).toHaveLength(1);
    const position = JSON.parse(
      await readFile(join(at.observe, "sessions", `${SESSION}.json`), "utf8"),
    );
    expect(position.gaps).toEqual([
      { cursor: "u-t-aaa1111-R1", at: expect.any(String) },
    ]);
  });

  test("journals the reviews harnexus left unsent, and refuses turns", async () => {
    const at = await place();
    const bridge = connect(at);
    await bridge.start("observe");
    const [review] = reviewsIn(judged("aaa1111"));

    await bridge.say({
      type: "event",
      event: "migration_unsent_reviews",
      entries: [{ parentThreadId: PARENT, review }],
    });
    await bridge.say({
      type: "event",
      event: "turn",
      turnId: "t1",
      threadId: "x",
      conversationId: "R1",
      kind: "input",
      text: "hi",
    });

    expect(
      (await journal(at)).filter((line) => line.kind === "legacy_unsent"),
    ).toEqual([expect.objectContaining({ parentThreadId: PARENT, review })]);
    expect(bridge.sent.filter((line) => line.type === "turn_end")).toEqual([
      expect.objectContaining({ turnId: "t1", status: "failed" }),
    ]);
    expect(bridge.requests()).toEqual([]);
  });
});

const projects = (path: string) => ({
  outcome: "done",
  result: {
    content: [
      {
        type: "text",
        text: JSON.stringify({
          projects: [{ projectId: "review-home", path }],
        }),
      },
    ],
  },
});

describe("a writing adapter", () => {
  test("declares the old reviewer chats, posts a review to its reviewer's chat, and opens a chat for a new reviewer", async () => {
    const at = await place();
    await mkdir(at.reviews, { recursive: true });
    await writeFile(
      join(at.reviews, "chats.json"),
      JSON.stringify({ R1: { threadId: "chat-r1", session: SESSION } }),
    );
    const bridge = connect(at, (request) => {
      if (request.op === "list_projects") return projects(at.reviewHome);
      if (request.op === "create_conversation")
        return { outcome: "done", threadId: "chat-r2" };
      return { outcome: "done", threadId: "chat-r1" };
    });
    await bridge.start("write");
    const records = [...judged("aaa1111"), ...judged("bbb2222", "R2")];

    await bridge.records({ phase: "linked", linkedAt: null, records: [] });
    await bridge.records({ phase: "continued", records });
    await bridge.say({
      type: "event",
      event: "turn",
      turnId: "t1",
      threadId: "chat-r2",
      conversationId: "R2",
      kind: "opened",
      text: "",
    });

    const [r1, r2] = reviewsIn(records);
    expect(bridge.sent.find((line) => line.type === "hello")).toMatchObject({
      bindings: [{ conversationId: "R1", threadId: "chat-r1" }],
    });
    expect(bridge.requests("post")).toEqual([
      expect.objectContaining({ conversationId: "R1", text: reviewText(r1!) }),
    ]);
    expect(bridge.requests("create_conversation")).toEqual([
      expect.objectContaining({
        conversationId: "R2",
        callerThreadId: PARENT,
        arguments: {
          target: {
            type: "project",
            projectId: "review-home",
            environment: { type: "local" },
          },
          title: "☁️ Review｜harnexus-1",
          model: "claude-sonnet-5-5",
        },
      }),
    ]);
    expect(bridge.sent.filter((line) => line.turnId === "t1")).toEqual([
      {
        v: 1,
        type: "turn_output",
        turnId: "t1",
        text: reviewText(r2!),
        phase: "final",
      },
      { v: 1, type: "turn_end", turnId: "t1", status: "completed" },
    ]);
    const chats = JSON.parse(
      await readFile(join(at.reviews, "chats.json"), "utf8"),
    );
    expect(chats).toEqual({
      R1: { threadId: "chat-r1", session: SESSION },
      R2: { threadId: "chat-r2", session: SESSION },
    });
    for (const review of [r1!, r2!])
      expect(
        JSON.parse(
          await readFile(join(at.reviews, `${review.key}.json`), "utf8"),
        ),
      ).toMatchObject({ sent: true });
    expect(await bridge.observations.pending()).toEqual(
      expect.objectContaining({ value: [] }),
    );
  });

  test("keeps a review the bridge surely did not show for the next try, and counts an unknown send as shown", async () => {
    const at = await place();
    await mkdir(at.reviews, { recursive: true });
    await writeFile(
      join(at.reviews, "chats.json"),
      JSON.stringify({ R1: "chat-r1" }),
    );
    const outcomes = ["not_sent", "unknown"];
    const bridge = connect(at, () => ({
      outcome: outcomes.shift() ?? "done",
      reason: "busy",
    }));
    await bridge.start("write");
    const [review] = reviewsIn(judged("aaa1111"));

    await bridge.records({ phase: "linked", linkedAt: null, records: [] });
    await bridge.records({ phase: "continued", records: judged("aaa1111") });
    const waiting = await bridge.observations.pending();
    const reservedAfterRefusal = (await reviewFiles(at)).includes(
      `${review!.key}.reserved`,
    );
    await bridge.records({ phase: "continued", records: judged("aaa1111") });
    await bridge.records({ phase: "continued", records: judged("aaa1111") });

    expect(
      waiting.isOk() && waiting.value.map((entry) => entry.review.key),
    ).toEqual([review!.key]);
    expect(reservedAfterRefusal).toBe(false);
    expect(bridge.requests("post")).toHaveLength(2);
    expect(
      JSON.parse(
        await readFile(join(at.reviews, `${review!.key}.json`), "utf8"),
      ),
    ).toMatchObject({ sent: true, threadId: "chat-r1" });
  });

  test("sends nothing for a review harnexus already sent or another adapter reserved", async () => {
    const at = await place();
    const [sent, reserved] = reviewsIn([
      ...judged("aaa1111"),
      ...judged("bbb2222"),
    ]);
    await mkdir(at.reviews, { recursive: true });
    await writeFile(
      join(at.reviews, "chats.json"),
      JSON.stringify({ R1: "chat-r1" }),
    );
    await writeFile(
      join(at.reviews, `${sent!.key}.json`),
      JSON.stringify({
        ...sent,
        sent: true,
        threadId: "chat-r1",
        shownAt: "2026-11-01T00:00:00Z",
      }),
    );
    await writeFile(join(at.reviews, `${reserved!.key}.reserved`), "{}");
    const bridge = connect(at);
    await bridge.start("write");

    await bridge.records({ phase: "linked", linkedAt: null, records: [] });
    await bridge.records({
      phase: "continued",
      records: [...judged("aaa1111"), ...judged("bbb2222")],
    });

    expect(bridge.requests("post")).toEqual([]);
    expect((await bridge.observations.pending()).unwrap()).toEqual([]);
  });

  test("shows a review once when two adapters take it at the same time", async () => {
    const at = await place();
    await mkdir(at.reviews, { recursive: true });
    await writeFile(
      join(at.reviews, "chats.json"),
      JSON.stringify({ R1: "chat-r1" }),
    );
    const one = connect(at);
    const two = connect(at);
    await Promise.all([one.start("write"), two.start("write")]);
    const [review] = reviewsIn(judged("aaa1111"));
    const entry = {
      parentThreadId: PARENT,
      sessionId: SESSION,
      review: review!,
    };
    await one.observations.keepPending([entry]);

    await Promise.all([
      one.say({ type: "ready", bindings: [], pending: [], conflicts: [] }),
      two.say({ type: "ready", bindings: [], pending: [], conflicts: [] }),
    ]);

    expect(one.requests("post").length + two.requests("post").length).toBe(1);
  });

  test("passes a message in a reviewer's chat to the session that ran the reviewer, and keeps it for the chat's history", async () => {
    const at = await place();
    await mkdir(at.reviews, { recursive: true });
    await writeFile(
      join(at.reviews, "chats.json"),
      JSON.stringify({
        R1: { threadId: "chat-r1", session: SESSION },
        R2: "chat-r2",
      }),
    );
    const [review] = reviewsIn(judged("aaa1111"));
    await writeFile(
      join(at.reviews, `${review!.key}.json`),
      JSON.stringify({
        ...review,
        sent: true,
        threadId: "chat-r1",
        shownAt: "2026-11-01T00:00:00.000Z",
      }),
    );
    const bridge = connect(at);
    await bridge.start("write");

    await bridge.say({
      type: "event",
      event: "turn",
      turnId: "t1",
      threadId: "chat-r1",
      conversationId: "R1",
      kind: "input",
      text: "B1 は？",
    });
    await bridge.say({
      type: "event",
      event: "turn",
      turnId: "t2",
      threadId: "chat-r2",
      conversationId: "R2",
      kind: "input",
      text: "hello",
    });
    await bridge.say({
      type: "request",
      id: "h1",
      op: "history",
      conversationId: "R1",
      threadId: "chat-r1",
    });

    expect(bridge.requests("cloud_send")).toEqual([
      expect.objectContaining({
        sessionId: SESSION,
        text: reviewerAsk("R1", "B1 は？"),
      }),
    ]);
    expect(
      bridge.sent
        .filter((line) => line.type === "turn_output")
        .map((line) => line.text),
    ).toEqual([REVIEW_ASK_SENT, REVIEW_ASK_UNROUTED]);
    const history = bridge.sent.find(
      (line) => line.type === "response" && line.id === "h1",
    );
    expect(history?.entries).toEqual([
      {
        role: "assistant",
        text: reviewText(review!),
        at: "2026-11-01T00:00:00.000Z",
      },
      { role: "user", text: "B1 は？", at: expect.any(String) },
      { role: "assistant", text: REVIEW_ASK_SENT, at: expect.any(String) },
    ]);
  });
});

describe("an adapter's records under failure and sharing", () => {
  test("moves its position only once a review is journaled, so a review it could not journal is taken when the records come again", async () => {
    const at = await place();
    const bridge = connect(at);
    await bridge.start("observe");
    await bridge.records({ phase: "linked", linkedAt: null, records: [] });
    await mkdir(join(at.observe, "journal.jsonl"));

    await bridge.records({ phase: "continued", records: judged("aaa1111") });
    const observedWhileFailing = bridge.sent.filter(
      (line) => line.type === "observed",
    ).length;
    await rm(join(at.observe, "journal.jsonl"), { recursive: true });
    await bridge.records({ phase: "continued", records: judged("aaa1111") });

    expect(observedWhileFailing).toBe(1);
    expect(
      bridge.sent
        .filter((line) => line.type === "observed")
        .map((line) => line.eventId),
    ).toEqual(["e1", "e3"]);
    expect(
      (await journal(at)).filter((line) => line.kind === "observed_review"),
    ).toHaveLength(1);
  });

  test("records the session that ran a review shown in a chat kept from before, so a message from the chat reaches it", async () => {
    const at = await place();
    await mkdir(at.reviews, { recursive: true });
    await writeFile(
      join(at.reviews, "chats.json"),
      JSON.stringify({ R1: "chat-r1" }),
    );
    const bridge = connect(at);
    await bridge.start("write");

    await bridge.records({ phase: "linked", linkedAt: null, records: [] });
    await bridge.records({ phase: "continued", records: judged("aaa1111") });
    await bridge.say({
      type: "event",
      event: "turn",
      turnId: "t1",
      threadId: "chat-r1",
      conversationId: "R1",
      kind: "input",
      text: "B1 は？",
    });

    expect(
      JSON.parse(await readFile(join(at.reviews, "chats.json"), "utf8")),
    ).toEqual({ R1: { threadId: "chat-r1", session: SESSION } });
    expect(bridge.requests("cloud_send")).toEqual([
      expect.objectContaining({ sessionId: SESSION }),
    ]);
  });

  test("keeps the reviews two adapters queue at once, and shows each", async () => {
    const at = await place();
    await mkdir(at.reviews, { recursive: true });
    await writeFile(
      join(at.reviews, "chats.json"),
      JSON.stringify({ R1: "chat-r1", R2: "chat-r2" }),
    );
    const one = connect(at);
    const two = connect(at);
    await Promise.all([one.start("write"), two.start("write")]);
    await one.say({
      type: "event",
      event: "session_records",
      eventId: "a0",
      sessionId: "session_A",
      parentThreadId: PARENT,
      link: PARENT,
      phase: "linked",
      linkedAt: null,
      shownBefore: null,
      records: [],
    });
    await two.say({
      type: "event",
      event: "session_records",
      eventId: "b0",
      sessionId: "session_B",
      parentThreadId: PARENT,
      link: PARENT,
      phase: "linked",
      linkedAt: null,
      shownBefore: null,
      records: [],
    });

    await Promise.all([
      one.say({
        type: "event",
        event: "session_records",
        eventId: "a1",
        sessionId: "session_A",
        parentThreadId: PARENT,
        link: PARENT,
        phase: "continued",
        shownBefore: null,
        records: judged("aaa1111"),
      }),
      two.say({
        type: "event",
        event: "session_records",
        eventId: "b1",
        sessionId: "session_B",
        parentThreadId: PARENT,
        link: PARENT,
        phase: "continued",
        shownBefore: null,
        records: judged("bbb2222", "R2"),
      }),
    ]);
    await settle();

    const posted = [...one.requests("post"), ...two.requests("post")]
      .map((line) => line.conversationId)
      .sort();
    expect(posted).toEqual(["R1", "R2"]);
    expect((await one.observations.pending()).unwrap()).toEqual([]);
  });

  test("keeps a review the bridge refused, such as for a binding conflict, until it can be shown", async () => {
    const at = await place();
    await mkdir(at.reviews, { recursive: true });
    await writeFile(
      join(at.reviews, "chats.json"),
      JSON.stringify({ R1: "chat-r1" }),
    );
    const answers = [
      { outcome: "rejected", reason: "binding_conflict" },
      { outcome: "invalid" },
    ];
    const bridge = connect(at, () => answers.shift() ?? { outcome: "done" });
    await bridge.start("write");
    const [review] = reviewsIn(judged("aaa1111"));

    await bridge.records({ phase: "linked", linkedAt: null, records: [] });
    await bridge.records({ phase: "continued", records: judged("aaa1111") });
    await bridge.records({ phase: "continued", records: judged("aaa1111") });
    const waiting = (await bridge.observations.pending()).unwrap();
    await bridge.records({ phase: "continued", records: judged("aaa1111") });

    expect(waiting.map((entry) => entry.review.key)).toEqual([review!.key]);
    expect(bridge.requests("post")).toHaveLength(3);
    expect((await bridge.observations.pending()).unwrap()).toEqual([]);
    expect(
      JSON.parse(
        await readFile(join(at.reviews, `${review!.key}.json`), "utf8"),
      ),
    ).toMatchObject({ sent: true });
  });
});

describe("a writing adapter's chats the bridge knows first", () => {
  test("records a binding only the bridge kept, and posts the next review to that chat", async () => {
    const at = await place();
    const bridge = connect(at);
    await bridge.say({
      type: "hello",
      bridgeId: "b1",
      adapterId: "taskctl",
      mode: "write",
      versions: [1],
    });
    await bridge.say({
      type: "ready",
      bridgeId: "b1",
      bindings: [{ conversationId: "R1", threadId: "chat-r1" }],
      pending: [],
      conflicts: [],
    });

    await bridge.records({ phase: "linked", linkedAt: null, records: [] });
    await bridge.records({ phase: "continued", records: judged("aaa1111") });

    expect(
      JSON.parse(await readFile(join(at.reviews, "chats.json"), "utf8")),
    ).toEqual({ R1: { threadId: "chat-r1", session: SESSION } });
    expect(bridge.requests("post")).toEqual([
      expect.objectContaining({ conversationId: "R1" }),
    ]);
    expect(bridge.requests("create_conversation")).toEqual([]);
  });

  test("posts the review when a create answers with a conversation the bridge already shows", async () => {
    const at = await place();
    const bridge = connect(at, (request) => {
      if (request.op === "list_projects") return projects(at.reviewHome);
      if (request.op === "create_conversation")
        return { outcome: "done", threadId: "chat-r1", existing: true };
      return { outcome: "done", threadId: "chat-r1" };
    });
    await bridge.start("write");
    const [review] = reviewsIn(judged("aaa1111"));

    await bridge.records({ phase: "linked", linkedAt: null, records: [] });
    await bridge.records({ phase: "continued", records: judged("aaa1111") });

    expect(bridge.requests("post")).toEqual([
      expect.objectContaining({
        conversationId: "R1",
        text: reviewText(review!),
      }),
    ]);
    expect(
      JSON.parse(
        await readFile(join(at.reviews, `${review!.key}.json`), "utf8"),
      ),
    ).toMatchObject({ sent: true, threadId: "chat-r1" });
  });

  test("shows the review in a chat whose create was unknown once its first turn arrives, without creating it again", async () => {
    const at = await place();
    const bridge = connect(at, (request) =>
      request.op === "list_projects"
        ? projects(at.reviewHome)
        : { outcome: "unknown", reason: "pending_create" },
    );
    await bridge.start("write");
    const [review] = reviewsIn(judged("aaa1111"));

    await bridge.records({ phase: "linked", linkedAt: null, records: [] });
    await bridge.records({ phase: "continued", records: judged("aaa1111") });
    await bridge.say({
      type: "event",
      event: "conversation_bound",
      conversationId: "R1",
      threadId: "chat-r1",
    });
    await bridge.say({
      type: "event",
      event: "turn",
      turnId: "t1",
      threadId: "chat-r1",
      conversationId: "R1",
      kind: "opened",
      text: "",
    });
    await bridge.records({ phase: "continued", records: judged("aaa1111") });

    expect(bridge.requests("create_conversation")).toHaveLength(1);
    expect(bridge.sent.filter((line) => line.turnId === "t1")).toEqual([
      {
        v: 1,
        type: "turn_output",
        turnId: "t1",
        text: reviewText(review!),
        phase: "final",
      },
      { v: 1, type: "turn_end", turnId: "t1", status: "completed" },
    ]);
    expect(
      JSON.parse(await readFile(join(at.reviews, "chats.json"), "utf8")),
    ).toEqual({ R1: { threadId: "chat-r1", session: SESSION } });
  });
});

describe("a writing adapter's later reviews of a reviewer whose chat is being opened", () => {
  const twoReviews = () => [...judged("aaa1111"), ...judged("bbb2222")];

  test("shows the first review when the chat's first turn comes, then the next, opening one chat", async () => {
    const at = await place();
    const bridge = connect(at, (request) => {
      if (request.op === "list_projects") return projects(at.reviewHome);
      if (request.op === "create_conversation")
        return { outcome: "unknown", reason: "pending_create" };
      return { outcome: "done", threadId: "chat-r1" };
    });
    await bridge.start("write");
    const [first, second] = reviewsIn(twoReviews());

    await bridge.records({ phase: "linked", linkedAt: null, records: [] });
    await bridge.records({ phase: "continued", records: twoReviews() });
    const postsBeforeTurn = bridge.requests("post").length;
    await bridge.say({
      type: "event",
      event: "conversation_bound",
      conversationId: "R1",
      threadId: "chat-r1",
    });
    await bridge.say({
      type: "event",
      event: "turn",
      turnId: "t1",
      threadId: "chat-r1",
      conversationId: "R1",
      kind: "opened",
      text: "",
    });
    await settle();

    expect(bridge.requests("create_conversation")).toHaveLength(1);
    expect(postsBeforeTurn).toBe(0);
    expect(bridge.sent.find((line) => line.type === "turn_output")?.text).toBe(
      reviewText(first!),
    );
    expect(bridge.requests("post").map((line) => line.text)).toEqual([
      reviewText(second!),
    ]);
    expect((await bridge.observations.pending()).unwrap()).toEqual([]);
  });

  test("posts the first review after a restart when the bridge bound its chat while the adapter was away, then the next", async () => {
    const at = await place();
    const before = connect(at, (request) =>
      request.op === "list_projects"
        ? projects(at.reviewHome)
        : { outcome: "unknown", reason: "pending_create" },
    );
    await before.start("write");
    const [first, second] = reviewsIn(twoReviews());
    await before.records({ phase: "linked", linkedAt: null, records: [] });
    await before.records({ phase: "continued", records: twoReviews() });

    const after = connect(at, () => ({ outcome: "done", threadId: "chat-r1" }));
    await after.say({
      type: "hello",
      bridgeId: "b1",
      adapterId: "taskctl",
      mode: "write",
      versions: [1],
    });
    await after.say({
      type: "ready",
      bridgeId: "b1",
      bindings: [{ conversationId: "R1", threadId: "chat-r1" }],
      pending: [],
      conflicts: [],
    });

    expect(after.requests("create_conversation")).toEqual([]);
    expect(after.requests("post").map((line) => line.text)).toEqual([
      reviewText(first!),
      reviewText(second!),
    ]);
    expect((await after.observations.pending()).unwrap()).toEqual([]);
  });
});

describe("handOver", () => {
  test("moves the journaled reviews nobody sent into the waiting list, which a writing adapter then shows", async () => {
    const at = await place();
    const [sentByHarnexus, observed, unsent] = reviewsIn([
      ...judged("aaa1111"),
      ...judged("bbb2222"),
      ...judged("ccc3333"),
    ]);
    const watcher = connect(at);
    await watcher.start("observe");
    await watcher.records({ phase: "linked", linkedAt: null, records: [] });
    await watcher.records({
      phase: "continued",
      records: [...judged("aaa1111"), ...judged("bbb2222")],
    });
    await watcher.say({
      type: "event",
      event: "migration_unsent_reviews",
      entries: [{ parentThreadId: PARENT, review: unsent }],
    });
    await mkdir(at.reviews, { recursive: true });
    await writeFile(
      join(at.reviews, `${sentByHarnexus!.key}.json`),
      JSON.stringify({
        ...sentByHarnexus,
        sent: true,
        threadId: "chat-r1",
        shownAt: "2026-11-01T00:00:00Z",
      }),
    );
    await writeFile(
      join(at.reviews, "chats.json"),
      JSON.stringify({ R1: { threadId: "chat-r1", session: SESSION } }),
    );

    const handed = await handOver(
      watcher.observations,
      watcher.store,
      await journal(at),
    );
    const again = await handOver(
      watcher.observations,
      watcher.store,
      await journal(at),
    );
    const writer = connect(at);
    await writer.start("write");

    expect(handed.unwrap()).toEqual({ handedOver: 2, skipped: 1 });
    expect(again.unwrap()).toEqual({ handedOver: 0, skipped: 1 });
    expect(writer.requests("post").map((line) => line.text)).toEqual([
      reviewText(observed!),
      reviewText(unsent!),
    ]);
  });
});
