import { join } from "node:path";

import { Result } from "better-result";

import { appendLine } from "../../lib/fs.boundary.ts";
import { isObject } from "../../lib/object.ts";
import { fail, type TaskFailed } from "../../task/format.ts";
import { load, saveJson, stateRoot } from "../../task/records.ts";
import { type Env, io } from "../../task/request.ts";
import type { CloudReview } from "./reviews.ts";

// Where taskctl keeps what it has seen of each Cloud session, apart from what the app shows, and the journal of the switch from harnexus's own review writer.
export const observationRoot = (env: Env) =>
  join(stateRoot(env), "cloud-observe");

// What taskctl has seen of one Cloud session.
export type SessionPosition = {
  sessionId: string;
  parentThreadId: string;
  // The record up to which reviews were in the session before taskctl first saw it, which are never opened; estimated when the bridge could only say what the app was last shown.
  baseline: { uuid: string | null; estimated: boolean; at: string };
  // The last record whose reviews were taken, or null before any was.
  cursor: string | null;
  // The reviews before the baseline, and every review taken since, so a session read again from its start is never opened twice.
  excluded: string[];
  taken: string[];
  // Cursors that were not found again, whose records may be lost; kept until someone checks them, never cleared on their own.
  gaps: { cursor: string; at: string }[];
};

// A review waiting to be shown, with the chat whose session ran it.
export type PendingReview = {
  parentThreadId: string;
  sessionId: string | null;
  review: CloudReview;
};

const SESSION_ID = /^[A-Za-z0-9_-]{1,128}$/;

const stringsOf = (value: unknown) =>
  Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];

const positionIn = (value: unknown): SessionPosition | null => {
  if (!isObject(value) || !isObject(value.baseline)) return null;
  const { baseline } = value;
  if (
    typeof value.sessionId !== "string" ||
    typeof value.parentThreadId !== "string"
  )
    return null;
  return {
    sessionId: value.sessionId,
    parentThreadId: value.parentThreadId,
    baseline: {
      uuid: typeof baseline.uuid === "string" ? baseline.uuid : null,
      estimated: baseline.estimated === true,
      at: typeof baseline.at === "string" ? baseline.at : "",
    },
    cursor: typeof value.cursor === "string" ? value.cursor : null,
    excluded: stringsOf(value.excluded),
    taken: stringsOf(value.taken),
    gaps: Array.isArray(value.gaps)
      ? value.gaps.flatMap((gap) =>
          isObject(gap) && typeof gap.cursor === "string"
            ? [
                {
                  cursor: gap.cursor,
                  at: typeof gap.at === "string" ? gap.at : "",
                },
              ]
            : [],
        )
      : [],
  };
};

const pendingIn = (value: unknown): PendingReview[] =>
  Array.isArray(value)
    ? value.flatMap((entry) => {
        if (!isObject(entry) || !isObject(entry.review)) return [];
        const { review } = entry;
        if (
          typeof entry.parentThreadId !== "string" ||
          typeof review.key !== "string" ||
          typeof review.reviewer !== "string" ||
          typeof review.answer !== "string"
        )
          return [];
        const text = (v: unknown) => (typeof v === "string" ? v : null);
        return [
          {
            parentThreadId: entry.parentThreadId,
            sessionId: text(entry.sessionId),
            review: {
              key: review.key,
              reviewer: review.reviewer,
              verdict: text(review.verdict),
              taskId: text(review.taskId),
              head: text(review.head),
              answer: review.answer,
            },
          },
        ];
      })
    : [];

export const createObservations = (root: string) => {
  const sessionPath = (sessionId: string) =>
    join(root, "sessions", `${sessionId}.json`);
  const pendingPath = join(root, "pending.json");
  const journalPath = join(root, "journal.jsonl");

  const position = (sessionId: string) =>
    Result.gen(async function* () {
      if (!SESSION_ID.test(sessionId))
        return fail(`${sessionId} is not a Cloud session id`);
      const loaded = yield* Result.await(load(sessionPath(sessionId)));
      if (loaded === null) return Result.ok<SessionPosition | null>(null);
      const found = positionIn(loaded);
      return found === null
        ? fail(`${sessionPath(sessionId)} is not a session position`)
        : Result.ok<SessionPosition | null>(found);
    });

  const keepPosition = (next: SessionPosition) =>
    saveJson(sessionPath(next.sessionId), next, { exclusive: false });

  const pending = () =>
    Result.gen(async function* () {
      const loaded = yield* Result.await(load(pendingPath));
      if (loaded !== null && !Array.isArray(loaded))
        return fail(`${pendingPath} is not a list`);
      return Result.ok(pendingIn(loaded));
    });

  const keepPending = (entries: readonly PendingReview[]) =>
    saveJson(pendingPath, entries, { exclusive: false });

  // Every line names when and what, so the switch can be checked and replayed from the journal alone.
  const note = (
    entry: Record<string, unknown>,
  ): Promise<Result<void, TaskFailed>> =>
    io(
      appendLine(
        journalPath,
        JSON.stringify({ at: new Date().toISOString(), ...entry }),
      ),
    );

  return {
    position,
    keepPosition,
    pending,
    keepPending,
    note,
    journalPath,
    pendingPath,
  };
};

export type Observations = ReturnType<typeof createObservations>;
