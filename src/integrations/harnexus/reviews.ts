import { createHash } from "node:crypto";

import { parseJson } from "../../lib/json.boundary.ts";
import { isObject } from "../../lib/object.ts";

// A Cloud session record as harnexus passes it on: Claude's own session messages, of which only the uuid and the content are read.
export type SessionRecord = Record<string, unknown>;

// A review harnexus-task review finished in a Cloud session, as its output names it.
export type CloudReview = {
  // Names the review by its reviewer, head, answer and, for a reply to a question, when it was asked, so a review read twice, such as from the file it was written to, is taken once.
  key: string;
  reviewer: string;
  verdict: string | null;
  taskId: string | null;
  head: string | null;
  answer: string;
};

const contentOf = (record: SessionRecord): Record<string, unknown>[] => {
  const message = record.message;
  const content = isObject(message) ? message.content : null;
  return Array.isArray(content) ? content.filter(isObject) : [];
};

const textsOf = (content: unknown) =>
  typeof content === "string"
    ? [content]
    : Array.isArray(content)
      ? content.flatMap((item) =>
          isObject(item) && typeof item.text === "string" ? [item.text] : [],
        )
      : [];

export const uuidOf = (record: SessionRecord | undefined) =>
  typeof record?.uuid === "string" ? record.uuid : null;

// The reviews whose output a Cloud session read at or after from, in order, each once; the output may be read from a file it was written to.
export const reviewsIn = (
  records: readonly SessionRecord[],
  from = 0,
  to = records.length,
): CloudReview[] => {
  const reviews = new Map<string, CloudReview>();
  for (const [index, record] of records.entries()) {
    if (index < from || index >= to) continue;
    for (const block of contentOf(record)) {
      if (block.type !== "tool_result" || block.is_error === true) continue;
      for (const text of textsOf(block.content)) {
        const review = reviewOf(text);
        if (review !== null && !reviews.has(review.key))
          reviews.set(review.key, review);
      }
    }
  }

  return [...reviews.values()];
};

// The output is harnexus-task's JSON, alone or with other lines around it, and with line numbers when a file was read.
const reviewOf = (text: string): CloudReview | null => {
  if (!text.includes('"reviewer"')) return null;
  const plain = text.replace(LINE_NUMBER, "");
  const start = plain.indexOf("{");
  const end = plain.lastIndexOf("}");
  if (start === -1 || end <= start) return null;
  const parsed = parseJson(plain.slice(start, end + 1));
  if (parsed.isErr() || !isObject(parsed.value)) return null;
  const output = parsed.value;
  if (
    output.status !== "completed" ||
    typeof output.reviewer !== "string" ||
    typeof output.answer !== "string" ||
    output.answer.trim() === ""
  )
    return null;
  const head = textOrNull(output.head);
  return {
    key: createHash("sha256")
      .update(
        `${output.reviewer}\0${head ?? ""}\0${textOrNull(output.askedAt) ?? ""}\0${output.answer}`,
      )
      .digest("hex")
      .slice(0, 32),
    reviewer: output.reviewer,
    verdict: textOrNull(output.verdict),
    taskId: textOrNull(output.taskId),
    head,
    answer: output.answer,
  };
};

const textOrNull = (value: unknown) =>
  typeof value === "string" && value !== "" ? value : null;

const LINE_NUMBER = /^ *\d+\t/gm;

// The mark that tells a chat showing a Cloud session from other chats in the app's list.
export const CLOUD_MARK = "☁️";

export const reviewText = (review: CloudReview) =>
  `${review.answer.trim()}\n\n_Codex reviewer \`${review.reviewer}\`${review.head === null ? "" : ` on \`${review.head.slice(0, 7)}\``}, run in a Cloud session. Ask for changes in the worker's chat._`;

// What the session that ran the reviewer is asked when the user writes in the reviewer's chat; the answer comes back as a review does.
export const reviewerAsk = (reviewer: string, text: string) =>
  `The user sent this to your Codex reviewer \`${reviewer}\` from its Review chat in the Codex App:\n\n${text}\n\nPass it to the same reviewer: write it to a file and run \`harnexus-crew review --request <your review request file> --ask <that file>\`, then reply with the reviewer's answer as it is.`;

export const REVIEW_ASK_SENT =
  "Sent to the worker running this reviewer, which passes it on; the reviewer's answer appears here once the worker's session is copied.";

export const REVIEW_ASK_UNROUTED =
  "The Cloud session that ran this reviewer is not shown in a chat here, so its answer could not come back and the message was not sent. Link the worker's session with /cloud, or ask in the worker's chat.";

export const REVIEW_ASK_UNKNOWN =
  "The message may or may not have reached the worker's session, so it is not sent again; check the worker's chat.";

// A /cloud-review message names one review kept in the folder, which old chats were opened with.
export const reviewCommandOf = (text: string) =>
  REVIEW_COMMAND.exec(text.trim())?.[1] ?? null;

const REVIEW_COMMAND = /^\/cloud-review\s+([A-Za-z0-9_-]{1,128})$/;
