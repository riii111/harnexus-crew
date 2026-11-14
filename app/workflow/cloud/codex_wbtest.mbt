///|
test "an unset or empty binary variable falls back to the default binary" {
  assert_eq(
    read_binary_path(@apptestkit.env_of([]), "BIN", "codex"),
    "codex",
    msg="unset",
  )
  assert_eq(
    read_binary_path(@apptestkit.env_of([("BIN", "")]), "BIN", "codex"),
    "codex",
    msg="empty",
  )
}

///|
test "an absolute path in the binary variable is the binary" {
  assert_eq(
    read_binary_path(
      @apptestkit.env_of([("BIN", "/opt/codex")]),
      "BIN",
      "codex",
    ),
    "/opt/codex",
  )
}

///|
async test "a relative path in the binary variable is refused" {
  assert_eq(
    @apptestkit.failure_of(() => {
      ignore(
        read_binary_path(@apptestkit.env_of([("BIN", "codex")]), "BIN", "codex"),
      )
    }),
    "BIN must be an absolute path",
  )
}

///|
test "an unset or empty duration falls back to the default duration" {
  assert_eq(read_milliseconds(@apptestkit.env_of([]), "T", 7), 7, msg="unset")
  assert_eq(
    read_milliseconds(@apptestkit.env_of([("T", "")]), "T", 7),
    7,
    msg="empty",
  )
}

///|
test "a positive whole number up to the 32-bit timer limit is the duration" {
  assert_eq(
    read_milliseconds(@apptestkit.env_of([("T", "1")]), "T", 7),
    1,
    msg="1",
  )
  assert_eq(
    read_milliseconds(@apptestkit.env_of([("T", "30000")]), "T", 7),
    30000,
    msg="30000",
  )
  assert_eq(
    read_milliseconds(@apptestkit.env_of([("T", "2147483647")]), "T", 7),
    2147483647,
    msg="2147483647",
  )
}

///|
async test "a duration over the 32-bit timer limit is refused" {
  for value in ["2147483648", "99999999999999999999999"] {
    assert_eq(
      @apptestkit.failure_of(() => {
        ignore(read_milliseconds(@apptestkit.env_of([("T", value)]), "T", 7))
      }),
      "T must be at most 2147483647 milliseconds",
      msg=value,
    )
  }
}

///|
async test "a duration that is not a positive whole number is refused" {
  for value in ["0", "05", "-1", "1.5", "1e3", "soon", " 5", "5 ", "٣", "+5"] {
    assert_eq(
      @apptestkit.failure_of(() => {
        ignore(read_milliseconds(@apptestkit.env_of([("T", value)]), "T", 7))
      }),
      "T must be a positive number of milliseconds",
      msg=value,
    )
  }
}

///|
test "a reply names the thread that thread.started gives, among other events" {
  assert_eq(reply_of(noisy_events()).thread_id, Some(REVIEWER))
}

///|
test "a reply answers with the last agent message, skipping other items" {
  assert_eq(reply_of(noisy_events()).answer, Some("last"))
}

///|
test "a reply fails with the message of turn.failed even when the turn completes after it" {
  assert_eq(reply_of(noisy_events()).failure, Some("late"))
}

///|
test "a thread that is not a lower-case UUID clears the one named before" {
  let named = "{\"type\":\"thread.started\",\"thread_id\":\"\{REVIEWER}\"}"
  let upper = "{\"type\":\"thread.started\",\"thread_id\":\"\{REVIEWER.to_upper()}\"}"
  let spaced = "{\"type\":\"thread.started\",\"thread_id\":\"\{REVIEWER}\\n\"}"

  assert_eq(reply_of("\{upper}\n\{named}").thread_id, Some(REVIEWER))
  assert_eq(reply_of("\{named}\n\{upper}").thread_id, None, msg="upper-case")
  assert_eq(reply_of("\{named}\n\{spaced}").thread_id, None, msg="newline")
}

///|
test "a thread id is a lower-case UUID" {
  for
    text in [
      REVIEWER,
      "",
      REVIEWER.to_upper(),
      "\{REVIEWER}\n",
      "01a18d52e03a74c1a50e4e697b47172b",
      "01a18d52-e03a-74c1-a50e-4e697b47172g",
    ] {
    assert_eq(is_thread_id(text), text == REVIEWER, msg=text.escape())
  }
}

///|
test "a failed turn names the message of its error" {
  assert_eq(
    failed_turn(",\"error\":{\"message\":\"rate limited\"}"),
    Some("rate limited"),
    msg="text",
  )
  assert_eq(
    failed_turn(",\"error\":{\"message\":429}"),
    Some("429"),
    msg="number",
  )
  assert_eq(
    failed_turn(",\"error\":{\"code\":429}"),
    Some("null"),
    msg="no message",
  )
}

///|
test "a failed turn without an error object says it failed" {
  assert_eq(
    failed_turn(",\"error\":\"text\""),
    Some("the turn failed"),
    msg="text error",
  )
  assert_eq(failed_turn(""), Some("the turn failed"), msg="no error")
}

///|
test "a verdict opens a line, after whitespace of any kind" {
  let cases = [
    ("判定: LGTM\n対象: …", "LGTM"),
    ("要約\n  判定:  修正必要\n以上", "修正必要"),
    ("判定:判定保留", "判定保留"),
    ("要約\r\n判定: LGTM", "LGTM"),
    ("要約\u{2028}判定: LGTM", "LGTM"),
    ("要約\u{2029}\u{3000}判定:\u{3000}LGTM", "LGTM"),
    ("x\n\u{FEFF}判定: LGTM", "LGTM"),
    ("x\n\u{A0}判定: LGTM", "LGTM"),
    ("\n\n判定:\n\nLGTM", "LGTM"),
  ]

  for case in cases {
    let (answer, verdict) = case
    assert_eq(verdict_of(answer), Some(verdict), msg=answer.escape())
  }
}

///|
test "the first verdict a reply names is the one that counts" {
  assert_eq(
    verdict_of("判定: 保留\n判定: 修正必要\n判定: LGTM"),
    Some("修正必要"),
  )
}

///|
test "text before the marker on its line, or a different word, is no verdict" {
  assert_eq(verdict_of("判定: LGTM"), Some("LGTM"))
  for
    answer in [
      "", "指摘はありません", "対象 判定: LGTM", "x \u{FEFF}判定: LGTM",
      "x\u{B}判定: LGTM", "判定：LGTM", "判定: lgtm", "判定: 保留", "判定: ",
      "判定:",
    ] {
    assert_eq(verdict_of(answer), None, msg=answer.escape())
  }
}

///|
test "a first review uses the default model and thinking, read-only in the checkout" {
  assert_eq(review_argv(None, "/repo", None, None), [
    "exec", "--json", "--sandbox", "read-only", "-C", "/repo", "-m", "gpt-6.1-sol",
    "-c", "model_reasoning_effort=\"medium\"", "-",
  ])
}

///|
test "a first review uses the model and thinking it is given" {
  assert_eq(review_argv(None, "/repo", Some("m"), Some("high")), [
    "exec", "--json", "--sandbox", "read-only", "-C", "/repo", "-m", "m", "-c", "model_reasoning_effort=\"high\"",
    "-",
  ])
}

///|
test "a first review treats an empty model and thinking as not given" {
  assert_eq(
    review_argv(None, "/repo", Some(""), Some("")),
    review_argv(None, "/repo", None, None),
  )
}

///|
test "a resumed review leaves the reviewer's own model and thinking alone" {
  assert_eq(review_argv(Some(REVIEWER), "/repo", None, None), [
    "exec",
    "resume",
    REVIEWER,
    "--json",
    "-c",
    "sandbox_mode=\"read-only\"",
    "-",
  ])
}

///|
test "a resumed review sets the model and thinking it is given" {
  assert_eq(review_argv(Some(REVIEWER), "/repo", Some("m"), Some("low")), [
    "exec",
    "resume",
    REVIEWER,
    "--json",
    "-c",
    "sandbox_mode=\"read-only\"",
    "-m",
    "m",
    "-c",
    "model_reasoning_effort=\"low\"",
    "-",
  ])
}

///|
test "a question resumes the reviewer read-only without a model or thinking" {
  assert_eq(ask_argv(REVIEWER), [
    "exec",
    "resume",
    REVIEWER,
    "--json",
    "-c",
    "sandbox_mode=\"read-only\"",
    "-",
  ])
}

///|
fn noisy_events() -> String {
  [
    "not json",
    "{\"type\":\"thread.started\",\"thread_id\":\"\{REVIEWER}\"}",
    "[1]",
    "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"first\"}}",
    "{\"type\":\"item.completed\",\"item\":{\"type\":\"reasoning\",\"text\":\"skip\"}}",
    "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":7}}",
    "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"last\"}}",
    "{\"type\":\"turn.failed\",\"error\":{\"message\":\"late\"}}",
    "{\"type\":\"turn.completed\"}",
    "{\"truncated\":",
  ].join("\n")
}

///|
fn failed_turn(error : String) -> String? {
  reply_of("{\"type\":\"turn.failed\"\{error}}").failure
}
