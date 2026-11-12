///|
/// A Cloud session record whose tool result carries `content`.
fn result_record(uuid : String, content : String) -> Json {
  parse(
    "{\"uuid\":\"\{uuid}\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\{content}}]}}",
  )
}

///|
fn review_output(extra : String) -> String {
  "{\"status\":\"completed\",\"reviewer\":\"r1\",\"verdict\":\"LGTM\",\"taskId\":\"TR1\",\"head\":\"0123456789abcdef\",\"answer\":\"Looks good.\\n\"\{extra}}"
}

///|
fn quoted(text : String) -> String {
  json_text(Json::string(text))
}

///|
fn or_none(text : String?) -> String {
  text.unwrap_or("none")
}

///|
fn summary(reviews : Array[CloudReview]) -> String {
  let parts = []
  for review in reviews {
    parts.push(
      "\{review.key} \{review.reviewer} \{or_none(review.verdict)} \{or_none(review.task_id)} \{or_none(review.head)} \{json_text(Json::string(review.answer))}",
    )
  }
  parts.join("; ")
}

///|
test "a review is read from the tool result that carries harnexus-task's output" {
  inspect(
    summary(reviews_in([result_record("u1", quoted(review_output("")))])),
    content="8f96d328f91be933ee7aed2c324d6875 r1 LGTM TR1 0123456789abcdef \"Looks good.\\n\"",
  )
}

///|
test "line numbers, surrounding lines and an array of texts do not change the review" {
  let numbered = "     1\t" +
    review_output("").replace_all(old=",", new=",\n   12\t")
  inspect(
    summary(reviews_in([result_record("u1", quoted(numbered))])),
    content="8f96d328f91be933ee7aed2c324d6875 r1 LGTM TR1 0123456789abcdef \"Looks good.\\n\"",
  )
  let asked = review_output(",\"askedAt\":\"2026-01-01T00:00:00.000Z\"")
  let texts = "[{\"type\":\"text\",\"text\":\{quoted("noise\n" + asked + "\ntrailer")}}]"
  inspect(
    summary(reviews_in([result_record("u1", texts)])),
    content="bbddc85c670169f22281fcce64c7de43 r1 LGTM TR1 0123456789abcdef \"Looks good.\\n\"",
  )
}

///|
test "only a line start with a number loses its prefix" {
  inspect(
    strip_line_numbers("  1\tab\n23\tcd\r45\tef\u{2028}6\tg\n 7 \th"),
    content="ab\ncd\ref\u{2028}g\n 7 \th",
  )
  inspect(strip_line_numbers("x 1\ty\n\t1\n12 "), content="x 1\ty\n\t1\n12 ")
  inspect(strip_line_numbers("1\t2\t3"), content="2\t3")
}

///|
test "a review read twice is taken once, and the range limits what is read" {
  let first = result_record("u1", quoted(review_output("")))
  let second = result_record(
    "u2",
    quoted(
      review_output("").replace_all(
        old="0123456789abcdef",
        new="ffffffffffffffff",
      ),
    ),
  )
  inspect(
    reviews_in([first, first, result_record("u3", quoted(review_output("")))]).length(),
    content="1",
  )
  inspect(
    summary(reviews_in([first, second], from=1)),
    content="0ac6e09193aa9513d7fd0420db43b7e6 r1 LGTM TR1 ffffffffffffffff \"Looks good.\\n\"",
  )
  inspect(
    summary(reviews_in([first, second], to=1)),
    content="8f96d328f91be933ee7aed2c324d6875 r1 LGTM TR1 0123456789abcdef \"Looks good.\\n\"",
  )
  inspect(reviews_in([first, second]).length(), content="2")
}

///|
test "output that is not a finished review is skipped" {
  let skipped = [
    "{\"type\":\"tool_result\",\"is_error\":true,\"content\":\{quoted(review_output(""))}}",
    "{\"type\":\"tool_use\",\"content\":\{quoted(review_output(""))}}",
    "{\"type\":\"tool_result\",\"content\":\{quoted(review_output("").replace_all(old="completed", new="failed"))}}",
    "{\"type\":\"tool_result\",\"content\":\{quoted(review_output("").replace_all(old="Looks good.\\n", new=" \\n "))}}",
    "{\"type\":\"tool_result\",\"content\":\{quoted("no reviewer here")}}",
    "{\"type\":\"tool_result\",\"content\":\{quoted("\"reviewer\" }{")}}",
    "{\"type\":\"tool_result\",\"content\":\{quoted("{\"reviewer\":1,\"status\":\"completed\",\"answer\":\"a\"}")}}",
    "{\"type\":\"tool_result\",\"content\":\{quoted("[\"reviewer\"]")}}",
  ]
  for block in skipped {
    let record = parse("{\"uuid\":\"u\",\"message\":{\"content\":[\{block}]}}")
    inspect(reviews_in([record]).length(), content="0")
  }
  for
    record in [
      "{\"uuid\":\"u\"}", "{\"message\":{\"content\":\"text\"}}", "null", "[]", "3",
    ] {
    inspect(reviews_in([parse(record)]).length(), content="0")
  }
}

///|
test "an empty head, verdict or task id reads as none" {
  let output = review_output("")
    .replace_all(old="\"head\":\"0123456789abcdef\"", new="\"head\":null")
    .replace_all(old="\"LGTM\"", new="\"\"")
    .replace_all(old="\"TR1\"", new="5")
  inspect(
    summary(reviews_in([result_record("u1", quoted(output))])),
    content="b46da86612504247ec2c44835d9803a1 r1 none none none \"Looks good.\\n\"",
  )
}

///|
test "the key hashes the UTF-8 of the reviewer, head, time and answer" {
  let output = "{\"status\":\"completed\",\"reviewer\":\"あ\",\"verdict\":\"LGTM\",\"taskId\":\"TR1\",\"head\":\"0123456789abcdef\",\"answer\":\"日本語🌙 ok\"}"
  inspect(
    summary(reviews_in([result_record("u1", quoted(output))])),
    content="e71308473ed0be6eb9919b0568e41f82 あ LGTM TR1 0123456789abcdef \"日本語🌙 ok\"",
  )
}

///|
test "a review is shown with the head cut to seven characters" {
  let review : CloudReview = {
    key: "k",
    reviewer: "r1",
    verdict: None,
    task_id: None,
    head: Some("0123456789abcdef"),
    answer: "  Looks good. \n",
  }
  inspect(
    review_text(review),
    content="Looks good.\n\n_Codex reviewer `r1` on `0123456`, run in a Cloud session. Ask for changes in the worker's chat._",
  )
  inspect(
    review_text({ ..review, head: None, answer: "ok", }),
    content="ok\n\n_Codex reviewer `r1`, run in a Cloud session. Ask for changes in the worker's chat._",
  )
}

///|
test "a question for a reviewer asks the session to pass it on" {
  inspect(
    reviewer_ask("r1", "why?"),
    content="The user sent this to your Codex reviewer `r1` from its Review chat in the Codex App:\n\nwhy?\n\nPass it to the same reviewer: write it to a file and run `harnexus-crew review --request <your review request file> --ask <that file>`, then reply with the reviewer's answer as it is.",
  )
}

///|
test "a /cloud-review message names one review" {
  let long = "a".repeat(128)
  for
    case in [
      ("/cloud-review abc", "abc"),
      (" /cloud-review   a-b_9 \n", "a-b_9"),
      ("/cloud-review", "none"),
      ("/cloud-review ", "none"),
      ("/cloud-reviewabc", "none"),
      ("/cloud-review a b", "none"),
      ("/cloud-review x", "x"),
      ("/cloud-review\u{FEFF}x", "x"),
      ("/cloud-review\u{3000}x", "x"),
      ("/cloud-review " + long, long),
      ("/cloud-review " + long + "a", "none"),
      ("/cloud-review é", "none"),
      ("/cloud-review\tx\n", "x"),
      ("cloud-review x", "none"),
    ] {
    let (text, expected) = case
    inspect(or_none(review_command_of(text)), content=expected)
  }
}

///|
test "a session record's uuid is read only from an object with a string uuid" {
  inspect(or_none(uuid_of(None)), content="none")
  inspect(or_none(uuid_of(Some(parse("{\"uuid\":\"x\"}")))), content="x")
  inspect(or_none(uuid_of(Some(parse("{\"uuid\":3}")))), content="none")
  inspect(or_none(uuid_of(Some(parse("{}")))), content="none")
  inspect(or_none(uuid_of(Some(parse("\"uuid\"")))), content="none")
}

///|
test "the Cloud mark is the cloud and its variation selector" {
  inspect(CLOUD_MARK.length(), content="2")
  inspect(json_text(Json::string(CLOUD_MARK)), content="\"\u{2601}\u{FE0F}\"")
}

///|
test "a head shorter than seven units is shown whole" {
  let review : CloudReview = {
    key: "k",
    reviewer: "r1",
    verdict: None,
    task_id: None,
    head: Some("abc"),
    answer: "ok",
  }
  inspect(
    review_text(review),
    content="ok\n\n_Codex reviewer `r1` on `abc`, run in a Cloud session. Ask for changes in the worker's chat._",
  )
  inspect(
    review_text({ ..review, head: Some("abcdefg"), }).contains("`abcdefg`"),
    content="true",
  )
}
