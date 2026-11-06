import type { SessionRecord } from "../reviews.ts";

// Synthetic records in the shape Claude Code's session messages take, as harnexus passes them on.

export const prompt = (uuid: string, text: string): SessionRecord => ({
  type: "user",
  uuid,
  message: { role: "user", content: text },
});

export const toolUse = (uuid: string, id: string): SessionRecord => ({
  type: "assistant",
  uuid,
  message: {
    role: "assistant",
    content: [{ type: "tool_use", id, name: "Bash", input: {} }],
  },
});

export const toolResult = (
  uuid: string,
  toolUseId: string,
  content: string,
  isError = false,
): SessionRecord => ({
  type: "user",
  uuid,
  message: {
    role: "user",
    content: [
      {
        type: "tool_result",
        tool_use_id: toolUseId,
        content,
        is_error: isError,
      },
    ],
  },
});

// harnexus-task review's output, as a Cloud session prints it.
export const reviewOutput = (fields: Record<string, unknown> = {}) =>
  JSON.stringify(
    {
      status: "completed",
      verdict: "LGTM",
      taskId: "harnexus-1",
      base: "b1",
      head: "abc1234def",
      reviewer: "0199-reviewer",
      answer: "判定: LGTM",
      state: "/tmp/state.json",
      ...fields,
    },
    null,
    1,
  );

// A tool call and its result, the two records a review run leaves.
export const ran = (id: string, content: string, isError = false) => [
  toolUse(`a-${id}`, id),
  toolResult(`u-${id}`, id, content, isError),
];
