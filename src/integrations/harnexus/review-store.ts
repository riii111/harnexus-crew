import { randomUUID } from "node:crypto";
import { dirname, join } from "node:path";

import { Result } from "better-result";

import { harnexusStatePath } from "../../app/socket-path.ts";
import {
  listDirectoryIfExists,
  prepareDirectory,
  readTextFileIfExists,
  removeFile,
  writeFileAtomic,
  writeFileExclusive,
} from "../../lib/fs.boundary.ts";
import { parseJson } from "../../lib/json.boundary.ts";
import { isObject } from "../../lib/object.ts";
import { fail, type TaskFailed } from "../../task/format.ts";
import { type Env, homeOf, io } from "../../task/request.ts";
import { withLock } from "./lock.ts";
import { type CloudReview, REVIEW_ASK_SENT, reviewText } from "./reviews.ts";

// harnexus kept the Cloud reviews beside its own state, and taskctl keeps them in place, in the same files, so either version reads the other's.
export const reviewsDirectory = (env: Env) =>
  harnexusStatePath(env, homeOf(env)).map((state) =>
    join(dirname(state), "cloud-reviews"),
  );

type ReadObject =
  | { kind: "missing" }
  | { kind: "unreadable" }
  | { kind: "object"; value: Record<string, unknown> };

export type ReviewerChat = { threadId: string; session: string | null };

export type HistoryEntry = {
  role: "user" | "assistant";
  text: string;
  at: string;
};

// Where a review stands in the folder: sent, kept but not sent, absent, or in a file that may stand over a sent one and so holds it.
export type ReviewState = "sent" | "unsent" | "missing" | "held";

const ASKED = "asked-";
// Made beside a review's file before it is sent, so of the adapters sharing the folder only one sends the review; it is not a .json file, so it is never read as a conversation record.
const RESERVED = ".reserved";
const CHATS = "chats.json";

// A reviewer's chat as the chats file keeps it; a file written before the session was kept names the chat alone.
const chatIn = (value: unknown): ReviewerChat | null => {
  if (typeof value === "string") return { threadId: value, session: null };
  if (!isObject(value) || typeof value.threadId !== "string") return null;
  return {
    threadId: value.threadId,
    session: typeof value.session === "string" ? value.session : null,
  };
};

// A review as its file keeps it, or null when the file names no reviewer and answer.
const reviewIn = (
  key: string,
  kept: Record<string, unknown> | null,
): CloudReview | null => {
  if (
    kept === null ||
    typeof kept.reviewer !== "string" ||
    typeof kept.answer !== "string"
  )
    return null;
  const text = (value: unknown) => (typeof value === "string" ? value : null);
  return {
    key,
    reviewer: kept.reviewer,
    verdict: text(kept.verdict),
    taskId: text(kept.taskId),
    head: text(kept.head),
    answer: kept.answer,
  };
};

// A file written before the review was sent, by harnexus or taskctl; anything else may stand over a sent review.
const isUnsentReviewFile = (kept: Record<string, unknown>, key: string) =>
  kept.key === key &&
  typeof kept.reviewer === "string" &&
  typeof kept.answer === "string" &&
  [kept.verdict, kept.taskId, kept.head].every(
    (value) =>
      value === undefined || value === null || typeof value === "string",
  ) &&
  !("sent" in kept) &&
  !("threadId" in kept) &&
  !("shownAt" in kept);

// The folder of Cloud reviews and their chats, shared by every adapter and by harnexus versions before the adapter.
export const createReviewStore = (dir: string, locks: string) => {
  const chatsPath = join(dir, CHATS);
  const reviewPath = (key: string) => join(dir, `${key}.json`);
  const reservationPath = (key: string) => join(dir, `${key}${RESERVED}`);

  const readObject = async (path: string): Promise<ReadObject> => {
    const text = await readTextFileIfExists(path);
    if (text.isErr()) return { kind: "unreadable" };
    if (text.value === null) return { kind: "missing" };
    const parsed = parseJson(text.value);
    return parsed.isOk() && isObject(parsed.value)
      ? { kind: "object", value: parsed.value }
      : { kind: "unreadable" };
  };

  const write = (path: string, value: object) =>
    Result.gen(async function* () {
      yield* Result.await(io(prepareDirectory(dir)));
      return await io(writeFileAtomic(path, JSON.stringify(value)));
    });

  // The chats file as it stands; an unreadable one is an error, so a chat is never opened again over one it may name.
  const chats = async (): Promise<
    Result<Map<string, ReviewerChat>, TaskFailed>
  > => {
    const read = await readObject(chatsPath);
    if (read.kind === "unreadable") return fail(`${chatsPath} is unreadable`);
    const found = new Map<string, ReviewerChat>();
    if (read.kind === "object")
      for (const [reviewer, value] of Object.entries(read.value)) {
        const chat = chatIn(value);
        if (chat !== null) found.set(reviewer, chat);
      }

    return Result.ok(found);
  };

  // Records the chat that shows a reviewer, under the lock every adapter takes for the file, so two never overwrite each other's entries.
  const keepChat = (reviewer: string, chat: ReviewerChat) =>
    withLock(locks, "chats", async () => {
      const read = await readObject(chatsPath);
      if (read.kind === "unreadable") return fail(`${chatsPath} is unreadable`);
      const latest = read.kind === "object" ? read.value : {};
      return write(chatsPath, { ...latest, [reviewer]: chat });
    });

  const stateOf = async (key: string): Promise<ReviewState> => {
    const kept = await readObject(reviewPath(key));
    if (kept.kind === "missing") return "missing";
    if (kept.kind === "unreadable") return "held";
    if (kept.value.sent === true) return "sent";
    return isUnsentReviewFile(kept.value, key) ? "unsent" : "held";
  };

  // Takes the review's reservation, which an adapter sharing the folder cannot take while it stands; only a reservation made here is ever removed.
  const claim = async (key: string) => {
    if ((await prepareDirectory(dir)).isErr()) return "failed";
    const made = await writeFileExclusive(
      reservationPath(key),
      JSON.stringify({ reservedAt: new Date().toISOString() }),
    );
    if (made.isOk()) return made.value ? "claimed" : "taken";
    // The reservation may be visible while its folder entry is lost in a crash, so it cannot allow a send; it was made here, so it is dropped.
    if (made.error._tag === "FileSyncFailed")
      await removeFile(reservationPath(key));
    return "failed";
  };

  const isReserved = async (key: string) =>
    (await readObject(reservationPath(key))).kind !== "missing";

  const unclaim = (key: string) => removeFile(reservationPath(key));

  const keepUnsent = (review: CloudReview) =>
    write(reviewPath(review.key), review);

  const markSent = (review: CloudReview, threadId: string | null) =>
    write(reviewPath(review.key), {
      ...review,
      sent: true,
      threadId,
      shownAt: new Date().toISOString(),
    });

  // Keeps a message the user sent the reviewer from its chat, for the chat's history.
  const noteAsk = (threadId: string, text: string) =>
    write(join(dir, `${ASKED}${Date.now()}-${randomUUID()}.json`), {
      threadId,
      shownAt: new Date().toISOString(),
      asked: text,
    });

  // The reviews shown in a reviewer's chat and the messages sent from it, oldest first, as the chat's history.
  const historyOf = async (threadId: string): Promise<HistoryEntry[]> => {
    const names = await listDirectoryIfExists(dir);
    if (names.isErr() || names.value === null) return [];
    const shown: { at: string; asked: boolean; entries: HistoryEntry[] }[] = [];
    for (const name of names.value) {
      if (!name.endsWith(".json") || name === CHATS) continue;
      const read = await readObject(join(dir, name));
      const kept = read.kind === "object" ? read.value : null;
      if (kept?.threadId !== threadId || typeof kept.shownAt !== "string")
        continue;
      const at = kept.shownAt;
      if (name.startsWith(ASKED)) {
        if (typeof kept.asked === "string")
          shown.push({
            at,
            asked: true,
            entries: [
              { role: "user", text: kept.asked, at },
              { role: "assistant", text: REVIEW_ASK_SENT, at },
            ],
          });
        continue;
      }

      const review = reviewIn(name.slice(0, -".json".length), kept);
      if (review !== null)
        shown.push({
          at,
          asked: false,
          entries: [{ role: "assistant", text: reviewText(review), at }],
        });
    }

    // A message is sent after the review it answers, so within one millisecond the review comes first rather than in the order the folder lists them.
    shown.sort(
      (a, b) => a.at.localeCompare(b.at) || Number(a.asked) - Number(b.asked),
    );
    return shown.flatMap((entry) => entry.entries);
  };

  // The review a /cloud-review message names, as its file keeps it.
  const reviewOf = async (key: string) => {
    const read = await readObject(reviewPath(key));
    return reviewIn(key, read.kind === "object" ? read.value : null);
  };

  return {
    chats,
    keepChat,
    stateOf,
    claim,
    isReserved,
    unclaim,
    keepUnsent,
    markSent,
    noteAsk,
    historyOf,
    reviewOf,
  };
};

export type ReviewStore = ReturnType<typeof createReviewStore>;
