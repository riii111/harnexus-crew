import { describe, expect, test } from "bun:test";

import { reviewsIn } from "./reviews.ts";
import {
  prompt,
  ran,
  reviewOutput as output,
} from "./testing/session-record.ts";

describe("reviewsIn", () => {
  test("reads a review harnexus-task printed, with what came around it, keyed as harnexus keyed it", () => {
    const records = [
      prompt("p1", "review it"),
      ...ran("t1", `exit=0\n${output({})}\n`),
    ];

    expect(reviewsIn(records)).toEqual([
      {
        key: KEY_OF_DEFAULT_OUTPUT,
        reviewer: "0199-reviewer",
        verdict: "LGTM",
        taskId: "harnexus-1",
        head: "abc1234def",
        answer: "判定: LGTM",
      },
    ]);
  });

  test("reads a review from a file read with line numbers", () => {
    const numbered = output({
      verdict: "修正必要",
      answer: "判定: 修正必要\n\n- B1",
    })
      .split("\n")
      .map((line, index) => `${String(index + 1).padStart(6)}\t${line}`)
      .join("\n");

    const [review] = reviewsIn(ran("t1", numbered));

    expect(review?.verdict).toBe("修正必要");
    expect(review?.answer).toBe("判定: 修正必要\n\n- B1");
  });

  test.each([
    { name: "a failed tool call", content: output({}), isError: true },
    {
      name: "a review that did not finish",
      content: output({ status: "failed" }),
      isError: false,
    },
    {
      name: "an answer left empty",
      content: output({ answer: " " }),
      isError: false,
    },
    {
      name: "text that only mentions a reviewer",
      content: 'the "reviewer" said {so}',
      isError: false,
    },
  ])("ignores $name", ({ content, isError }) => {
    expect(reviewsIn(ran("t1", content, isError))).toEqual([]);
  });

  test("tells apart replies of the same text to questions asked at different times", () => {
    const records = [
      ...ran(
        "t1",
        output({
          kind: "reply",
          askedAt: "2026-11-01T00:00:00Z",
          answer: "はい",
        }),
      ),
      ...ran(
        "t2",
        output({
          kind: "reply",
          askedAt: "2026-11-01T00:05:00Z",
          answer: "はい",
        }),
      ),
      ...ran(
        "t3",
        output({
          kind: "reply",
          askedAt: "2026-11-01T00:05:00Z",
          answer: "はい",
        }),
      ),
    ];

    expect(reviewsIn(records)).toHaveLength(2);
  });

  test("takes only the reviews read in the given range of records", () => {
    const records = [
      ...ran("t1", output({})),
      ...ran("t2", output({ head: "fff0000" })),
      ...ran("t3", output({ head: "eee0000" })),
    ];

    expect(reviewsIn(records, 2, 4).map((review) => review.head)).toEqual([
      "fff0000",
    ]);
  });
});

// The key harnexus 8127612's reviewsIn gives the default output, so files it kept are found by the same name.
const KEY_OF_DEFAULT_OUTPUT = "bb76e868a41741867e6b5a6086bc1a30";
