import { createHash } from "node:crypto";

import { Result } from "better-result";

import { projectsIn } from "../../app/projects.ts";
import { realPathOrSelf } from "../../lib/fs.boundary.ts";
import { parseJson } from "../../lib/json.boundary.ts";
import { isObject } from "../../lib/object.ts";
import type { TaskFailed } from "../../task/format.ts";
import { withLock } from "./lock.ts";
import type {
  Observations,
  PendingReview,
  SessionPosition,
} from "./observations.ts";
import type { ReviewStore } from "./review-store.ts";
import {
  CLOUD_MARK,
  type CloudReview,
  REVIEW_ASK_SENT,
  REVIEW_ASK_UNKNOWN,
  REVIEW_ASK_UNROUTED,
  reviewCommandOf,
  reviewerAsk,
  reviewsIn,
  reviewText,
  type SessionRecord,
  uuidOf,
} from "./reviews.ts";

export const ADAPTER_PROTOCOL_VERSION = 1;

type Line = Record<string, unknown>;

// What the bridge answered a request, as harnexus's adapter protocol 1 names it.
type Answer = {
  outcome: string;
  reason?: string;
  message?: string;
  [key: string]: unknown;
};

// The requests that open, answer or send for a conversation, which an observing adapter never sends.
const WRITE_OPS = new Set([
  "create_conversation",
  "bind_conversation",
  "post",
  "cloud_send",
]);

// Outcomes after which a review was surely not shown, so it stays waiting for the next try.
// rejected and invalid are refusals of a request that was not carried out, so the review waits until their cause, such as a binding conflict, is cleared.
const RETRIED = new Set([
  "not_sent",
  "rejected",
  "invalid",
  "no_project",
  "not_kept",
  "held",
]);

const REVIEW_CHAT_MODEL = "claude-sonnet-5-5";

const REVIEW_MISSING =
  "This review is no longer kept on this Mac, so it cannot be shown here.";

export type AdapterDeps = {
  adapterId: string;
  send: (line: string) => void;
  store: ReviewStore;
  observations: Observations;
  // Where the locks every adapter on the machine shares are kept.
  locks: string;
  // The empty project reviewers run in, where a reviewer's chat is opened.
  reviewHome: string;
  // Called with what the adapter could not do, for its own log; never sent to the bridge.
  log: (entry: Line) => void;
};

// Runs one connection to a harnexus bridge: it takes the reviews Cloud sessions print, keeps what it has seen of each session, and in write mode shows each review once in its reviewer's chat.
export const createAdapter = (deps: AdapterDeps) => {
  const { store, observations } = deps;
  let mode: "observe" | "write" | null = null;
  let ready = false;
  let nextId = 0;
  const asks = new Map<string, (answer: Answer) => void>();
  // The text a reviewer's new chat opens with, kept until its first turn asks for it.
  const openingTexts = new Map<string, string>();
  const sessionsOfReviewer = new Map<string, string | null>();
  // Events change the shared records one at a time, in the order they came.
  let chain: Promise<unknown> = Promise.resolve();
  const inOrder = (work: () => Promise<unknown>) => {
    chain = chain.then(work, work);
    return chain;
  };

  const sendLine = (line: Line) =>
    deps.send(JSON.stringify({ v: ADAPTER_PROTOCOL_VERSION, ...line }));

  // Journals the entry, saying in the log when it could not be kept.
  const noted = async (entry: Line) => {
    const kept = await observations.note(entry);
    if (kept.isErr())
      deps.log({ step: "journal_unwritable", message: kept.error.message });
    return kept.isOk();
  };

  const request = (op: string, fields: Line): Promise<Answer> => {
    // Checked here as well as by the bridge, so an observing adapter writes nothing even to a bridge that would take it.
    if (mode !== "write" && WRITE_OPS.has(op))
      return Promise.resolve({ outcome: "not_sent", reason: "observe_only" });
    nextId += 1;
    const id = `taskctl-${nextId}`;
    const answered = new Promise<Answer>((resolve) => asks.set(id, resolve));
    sendLine({ type: "request", id, op, ...fields });
    return answered;
  };

  const lockName = (reviewer: string) =>
    `reviewer-${createHash("sha256").update(reviewer).digest("hex").slice(0, 16)}`;

  const declaredBindings = async () => {
    const chats = await store.chats();
    if (chats.isErr()) {
      deps.log({ step: "chats_unreadable", message: chats.error.message });
      return [];
    }

    return [...chats.value].map(([reviewer, chat]) => ({
      conversationId: reviewer,
      threadId: chat.threadId,
    }));
  };

  const greet = async (hello: Line) => {
    const versions = Array.isArray(hello.versions) ? hello.versions : [];
    if (!versions.includes(ADAPTER_PROTOCOL_VERSION)) {
      deps.log({ step: "version_refused" });
      return;
    }

    mode = hello.mode === "write" ? "write" : "observe";
    // Old reviewer chats are declared from the chats file, the record of which chat shows which reviewer, so the bridge binds them again.
    sendLine({
      type: "hello",
      adapterId: deps.adapterId,
      bindings: mode === "write" ? await declaredBindings() : [],
    });
  };

  // The project whose folder is the review home itself.
  const reviewProject = async (result: unknown) => {
    const real = await realPathOrSelf(deps.reviewHome);
    for (const project of projectsIn(result))
      if (
        isObject(project) &&
        typeof project.projectId === "string" &&
        typeof project.path === "string" &&
        (await realPathOrSelf(project.path)) === real
      )
        return project.projectId;
    return null;
  };

  const openChat = async (entry: PendingReview, text: string) => {
    const { review, parentThreadId } = entry;
    const listed = await request("list_projects", {
      callerThreadId: parentThreadId,
    });
    if (listed.outcome !== "done")
      return { outcome: "not_sent", threadId: null };
    const projectId = await reviewProject(listed.result);
    if (projectId === null) return { outcome: "no_project", threadId: null };
    openingTexts.set(review.reviewer, text);
    sessionsOfReviewer.set(review.reviewer, entry.sessionId);
    const created = await request("create_conversation", {
      conversationId: review.reviewer,
      callerThreadId: parentThreadId,
      arguments: {
        target: { type: "project", projectId, environment: { type: "local" } },
        title: `${CLOUD_MARK} Review｜${review.taskId ?? review.reviewer}`,
        model: REVIEW_CHAT_MODEL,
      },
    });
    const threadId =
      typeof created.threadId === "string" ? created.threadId : null;
    if (created.outcome !== "done") openingTexts.delete(review.reviewer);
    if (threadId !== null)
      await store.keepChat(review.reviewer, {
        threadId,
        session: entry.sessionId,
      });
    return { outcome: created.outcome, threadId };
  };

  // Shows the review in its reviewer's chat, once across every adapter sharing the folder; a send whose outcome is unknown counts as shown.
  const deliver = (entry: PendingReview): Promise<Result<string, TaskFailed>> =>
    withLock(deps.locks, lockName(entry.review.reviewer), async () => {
      const { review } = entry;
      const state = await store.stateOf(review.key);
      if (state === "sent") return Result.ok("done");
      if (state === "held") return Result.ok("held");
      const claimed = await store.claim(review.key);
      if (claimed === "taken")
        return Result.ok(
          (await store.stateOf(review.key)) === "sent" ? "done" : "reserved",
        );
      if (claimed === "failed") return Result.ok("not_kept");
      const kept = await store.keepUnsent(review);
      const chats = kept.isOk() ? await store.chats() : null;
      if (chats === null || chats.isErr()) {
        await store.unclaim(review.key);
        return Result.ok(chats === null ? "not_kept" : "held");
      }

      const text = reviewText(review);
      const chat = chats.value.get(review.reviewer);
      let shown: { outcome: string; threadId: string | null } | null = null;
      if (chat !== undefined) {
        const posted = await request("post", {
          conversationId: review.reviewer,
          text,
        });
        // Only a chat the bridge no longer binds is replaced by a new one.
        if (!(posted.outcome === "rejected" && posted.reason === "unbound"))
          shown = { outcome: posted.outcome, threadId: chat.threadId };
        // A message from the chat goes to the session that ran this review, which a chat kept from before may not name yet.
        if (
          (posted.outcome === "done" || posted.outcome === "unknown") &&
          entry.sessionId !== null &&
          chat.session !== entry.sessionId
        ) {
          const kept = await store.keepChat(review.reviewer, {
            threadId: chat.threadId,
            session: entry.sessionId,
          });
          if (kept.isErr())
            deps.log({ step: "chat_unwritable", message: kept.error.message });
        }
      }

      shown ??= await openChat(entry, text);
      if (shown.outcome === "done" || shown.outcome === "unknown") {
        const marked = await store.markSent(review, shown.threadId);
        if (marked.isErr())
          deps.log({ step: "sent_not_recorded", key: review.key });
      } else {
        await store.unclaim(review.key);
      }

      return Result.ok(shown.outcome);
    });

  // Tries every waiting review once, keeping those surely not shown for the next try.
  const drain = async () => {
    if (mode !== "write" || !ready) return;
    const waiting = await observations.pending();
    if (waiting.isErr()) {
      deps.log({ step: "pending_unreadable", message: waiting.error.message });
      return;
    }

    const settled = new Set<string>();
    for (const entry of waiting.value) {
      const delivered = await deliver(entry);
      const outcome = delivered.isOk() ? delivered.value : "not_kept";
      await observations.note({
        kind: "delivered",
        key: entry.review.key,
        outcome,
      });
      if (!RETRIED.has(outcome)) settled.add(entry.review.key);
    }

    // Only the reviews settled here leave the list, so one another adapter added meanwhile stays.
    const removed = await observations.removePending(settled);
    if (removed.isErr())
      deps.log({ step: "pending_unwritable", message: removed.error.message });
  };

  const firstPosition = async (
    event: Line,
    records: readonly SessionRecord[],
  ) => {
    const linked = event.phase === "linked";
    // A linked session is measured from the record the chat was linked at; a session first seen continuing is measured from what the app was last shown, which a restarted bridge may only estimate.
    const base = linked
      ? typeof event.linkedAt === "string"
        ? event.linkedAt
        : uuidOf(records.at(-1))
      : typeof event.shownBefore === "string"
        ? event.shownBefore
        : null;
    const found =
      base === null
        ? -1
        : records.findIndex((record) => uuidOf(record) === base);
    // A base not among the records leaves every review in them out, so nothing from before the link is opened.
    const end = base === null ? 0 : found === -1 ? records.length : found + 1;
    if (
      !linked &&
      !(await noted({
        kind: "baseline_estimated",
        sessionId: event.sessionId,
        shownBefore: base,
      }))
    )
      return null;
    if (
      base !== null &&
      found === -1 &&
      !(await noted({
        kind: "baseline_missing",
        sessionId: event.sessionId,
        base,
      }))
    )
      return null;
    const position: SessionPosition = {
      sessionId: String(event.sessionId),
      parentThreadId: String(event.parentThreadId),
      baseline: {
        uuid: base,
        estimated: !linked,
        at: new Date().toISOString(),
      },
      cursor: uuidOf(records[end - 1]),
      excluded: reviewsIn(records, 0, end).map((review) => review.key),
      taken: [],
      gaps: [],
    };
    return { position, from: end };
  };

  const takeRecords = async (event: Line) => {
    const sessionId =
      typeof event.sessionId === "string" ? event.sessionId : "";
    const records = Array.isArray(event.records)
      ? event.records.filter(isObject)
      : [];
    const known = await observations.position(sessionId);
    if (known.isErr()) {
      deps.log({ step: "position_unreadable", message: known.error.message });
      return;
    }

    let position: SessionPosition;
    let from: number;
    if (known.value === null) {
      const first = await firstPosition(event, records);
      if (first === null) return;
      ({ position, from } = first);
    } else {
      position = known.value;
      const at =
        position.cursor === null
          ? -1
          : records.findIndex((record) => uuidOf(record) === position.cursor);
      // A cursor not found again may mean lost records; every record is read again, the kept keys keep out what was taken, and the gap stays recorded.
      if (position.cursor !== null && at === -1) {
        position.gaps.push({
          cursor: position.cursor,
          at: new Date().toISOString(),
        });
        if (
          !(await noted({
            kind: "cursor_missing",
            sessionId,
            cursor: position.cursor,
          }))
        )
          return;
      }

      from = at + 1;
    }

    const seen = new Set([...position.excluded, ...position.taken]);
    const fresh = reviewsIn(records, from).filter(
      (review) => !seen.has(review.key),
    );
    const parentThreadId = String(event.parentThreadId);
    const entries = fresh.map((review): PendingReview => ({
      parentThreadId,
      sessionId,
      review,
    }));
    // Every review is journaled, and in write mode queued, before the position moves past it; a failure leaves the position, so the records are read again.
    for (const entry of entries)
      if (
        !(await noted({
          kind: mode === "write" ? "review_taken" : "observed_review",
          sessionId,
          parentThreadId,
          review: entry.review,
        }))
      )
        return;
    if (mode === "write" && entries.length > 0) {
      const queued = await observations.addPending(entries);
      if (queued.isErr()) {
        deps.log({ step: "pending_unwritable", message: queued.error.message });
        return;
      }
    }

    position.taken.push(...fresh.map((review) => review.key));
    position.cursor = uuidOf(records.at(-1)) ?? position.cursor;
    position.parentThreadId = parentThreadId;
    const kept = await observations.keepPosition(position);
    // The bridge is told only once the position is kept, so a crash before it reads the records again.
    if (kept.isOk() && typeof event.eventId === "string")
      sendLine({ type: "observed", eventId: event.eventId });
  };

  const takeLegacyUnsent = async (event: Line) => {
    if (mode !== "observe") return;
    const entries = Array.isArray(event.entries)
      ? event.entries.filter(isObject)
      : [];
    // The bridge names them again at each connection, so one that could not be journaled is taken at the next.
    for (const entry of entries)
      await noted({
        kind: "legacy_unsent",
        parentThreadId: entry.parentThreadId,
        review: entry.review,
      });
  };

  const endTurn = (
    turnId: string,
    text: string | null,
    failed: string | null = null,
  ) => {
    if (text !== null)
      sendLine({ type: "turn_output", turnId, text, phase: "final" });
    sendLine({
      type: "turn_end",
      turnId,
      status: failed === null ? "completed" : "failed",
      ...(failed !== null && { message: failed }),
    });
  };

  // A message the user wrote in a reviewer's chat goes to the Cloud session that ran the reviewer, which passes it on.
  const askReviewer = async (
    turnId: string,
    threadId: string,
    reviewer: string,
    text: string,
  ) => {
    const typed = reviewCommandOf(text);
    if (typed !== null) {
      const review = await store.reviewOf(typed);
      endTurn(turnId, review === null ? REVIEW_MISSING : reviewText(review));
      return;
    }

    const chats = await store.chats();
    const session = chats.isOk()
      ? (chats.value.get(reviewer)?.session ?? null)
      : null;
    if (session === null) {
      endTurn(turnId, REVIEW_ASK_UNROUTED);
      return;
    }

    const sent = await request("cloud_send", {
      sessionId: session,
      text: reviewerAsk(reviewer, text),
    });
    if (sent.outcome === "done") {
      await store.noteAsk(threadId, text);
      endTurn(turnId, REVIEW_ASK_SENT);
    } else if (sent.outcome === "rejected" && sent.reason === "not_linked")
      endTurn(turnId, REVIEW_ASK_UNROUTED);
    else if (sent.outcome === "unknown")
      endTurn(turnId, null, REVIEW_ASK_UNKNOWN);
    else
      endTurn(
        turnId,
        null,
        `The message was not sent (${sent.outcome}${sent.reason === undefined ? "" : `: ${sent.reason}`}).`,
      );
  };

  const takeTurn = async (event: Line) => {
    const turnId = String(event.turnId);
    const conversation = String(event.conversationId);
    if (mode !== "write") {
      endTurn(turnId, null, "taskctl only observes for this bridge.");
      return;
    }

    if (event.kind === "opened") {
      const text = openingTexts.get(conversation) ?? null;
      openingTexts.delete(conversation);
      endTurn(turnId, text);
      return;
    }

    await askReviewer(
      turnId,
      String(event.threadId),
      conversation,
      typeof event.text === "string" ? event.text : "",
    );
  };

  const takeBound = async (event: Line) => {
    const reviewer = String(event.conversationId);
    const threadId = String(event.threadId);
    const chats = await store.chats();
    if (chats.isErr() || chats.value.get(reviewer)?.threadId === threadId)
      return;
    await store.keepChat(reviewer, {
      threadId,
      session: sessionsOfReviewer.get(reviewer) ?? null,
    });
  };

  const answerHistory = async (line: Line) => {
    const threadId = typeof line.threadId === "string" ? line.threadId : "";
    sendLine({
      type: "response",
      id: line.id,
      outcome: "done",
      entries: await store.historyOf(threadId),
    });
  };

  const receive = async (raw: string) => {
    const parsed = parseJson(raw);
    const line = parsed.isOk() && isObject(parsed.value) ? parsed.value : null;
    if (line === null || line.v !== ADAPTER_PROTOCOL_VERSION) {
      deps.log({ step: "line_invalid" });
      return;
    }

    switch (line.type) {
      case "hello":
        await greet(line);
        return;
      case "ready":
        ready = true;
        if (Array.isArray(line.conflicts) && line.conflicts.length > 0)
          deps.log({ step: "binding_conflicts", threads: line.conflicts });
        await inOrder(drain);
        return;
      case "response": {
        const answer = asks.get(String(line.id));
        asks.delete(String(line.id));
        answer?.({
          ...line,
          outcome: typeof line.outcome === "string" ? line.outcome : "unknown",
        });
        return;
      }

      case "request":
        if (line.op === "history") await answerHistory(line);
        return;
      case "event":
        switch (line.event) {
          case "session_records":
            await inOrder(async () => {
              await takeRecords(line);
              await drain();
            });
            return;
          case "migration_unsent_reviews":
            await inOrder(() => takeLegacyUnsent(line));
            return;
          case "turn":
            await takeTurn(line);
            return;
          case "conversation_bound":
            await takeBound(line);
            return;
          default:
            return;
        }

      default:
        deps.log({ step: "line_unknown", type: line.type });
    }
  };

  return { receive, mode: () => mode };
};

// Moves the reviews the journal recorded while only observing into the waiting list, except those harnexus or another adapter already sent or reserved; run while no adapter runs.
export const handOver = (
  observations: Observations,
  store: ReviewStore,
  journal: readonly Line[],
) =>
  Result.gen(async function* () {
    const waiting = yield* Result.await(observations.pending());
    const queued = new Set(waiting.map((entry) => entry.review.key));
    const added: PendingReview[] = [];
    let skipped = 0;
    for (const line of journal) {
      if (line.kind !== "observed_review" && line.kind !== "legacy_unsent")
        continue;
      const review = isObject(line.review)
        ? (line.review as CloudReview)
        : null;
      if (
        review === null ||
        typeof review.key !== "string" ||
        typeof line.parentThreadId !== "string"
      )
        continue;
      if (queued.has(review.key)) continue;
      queued.add(review.key);
      if (
        (await store.stateOf(review.key)) === "sent" ||
        (await store.isReserved(review.key))
      ) {
        skipped += 1;
        yield* Result.await(
          observations.note({ kind: "handover_skipped", key: review.key }),
        );
        continue;
      }

      added.push({
        parentThreadId: line.parentThreadId,
        sessionId: typeof line.sessionId === "string" ? line.sessionId : null,
        review,
      });
      yield* Result.await(
        observations.note({ kind: "handed_over", key: review.key }),
      );
    }

    yield* Result.await(observations.addPending(added));
    return Result.ok({ handedOver: added.length, skipped });
  });
