///|
const REVIEWER : String = "01a18d52-e03a-74c1-a50e-4e697b47172b"

///|
fn env_of(pairs : Array[(String, String)]) -> @environment.Env {
  let vars = Map([])
  for pair in pairs {
    let (name, value) = pair
    vars[name] = value
  }
  @environment.Env::new(vars, login_home="/login")
}

///|
fn failure_text(work : () -> Unit raise @failure.TaskFailed) -> String {
  try {
    work()
    ""
  } catch {
    failed => failed.message()
  }
}

///|
test "the Codex binary is codex unless an absolute path is set" {
  assert_eq(configured_binary(env_of([]), "BIN", "codex"), "codex")
  assert_eq(configured_binary(env_of([("BIN", "")]), "BIN", "codex"), "codex")
  assert_eq(
    configured_binary(env_of([("BIN", "/opt/codex")]), "BIN", "codex"),
    "/opt/codex",
  )
  inspect(
    failure_text(() => {
      ignore(configured_binary(env_of([("BIN", "codex")]), "BIN", "codex"))
    }),
    content="BIN must be an absolute path",
  )
}

///|
test "a duration is a positive whole number of at most ten digits" {
  assert_eq(milliseconds(env_of([]), "T", 7), 7)
  assert_eq(milliseconds(env_of([("T", "")]), "T", 7), 7)
  assert_eq(milliseconds(env_of([("T", "1")]), "T", 7), 1)
  assert_eq(milliseconds(env_of([("T", "30000")]), "T", 7), 30000)
  assert_eq(milliseconds(env_of([("T", "2147483647")]), "T", 7), 2147483647)
  // A timer that long cannot be set, so it runs for 1 millisecond.
  assert_eq(milliseconds(env_of([("T", "2147483648")]), "T", 7), 1)
  assert_eq(milliseconds(env_of([("T", "9999999999")]), "T", 7), 1)
  for
    value in [
      "0", "05", "-1", "1.5", "1e3", "soon", " 5", "5 ", "10000000000", "٣", "+5",
    ] {
    inspect(
      failure_text(() => ignore(milliseconds(env_of([("T", value)]), "T", 7))),
      content="T must be a positive number of milliseconds",
    )
  }
}

///|
test "the reply is the thread, the last agent message and the failure the events name" {
  let events = [
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
  ]
  let reply = reply_of(events.join("\n"))
  assert_eq(reply.thread_id, Some(REVIEWER))
  assert_eq(reply.answer, Some("last"))
  assert_eq(reply.failure, Some("late"))
}

///|
test "a thread that is not a lower-case UUID clears the one named before" {
  let named = "{\"type\":\"thread.started\",\"thread_id\":\"\{REVIEWER}\"}"
  let upper = "{\"type\":\"thread.started\",\"thread_id\":\"\{REVIEWER.to_upper()}\"}"
  assert_eq(reply_of("\{named}\n\{upper}").thread_id, None)
  assert_eq(reply_of("\{upper}\n\{named}").thread_id, Some(REVIEWER))
  let spaced = "{\"type\":\"thread.started\",\"thread_id\":\"\{REVIEWER}\\n\"}"
  assert_eq(reply_of(spaced).thread_id, None)
  assert_true(is_thread_id(REVIEWER))
  assert_false(is_thread_id(""))
  assert_false(is_thread_id("01a18d52e03a74c1a50e4e697b47172b"))
  assert_false(is_thread_id("01a18d52-e03a-74c1-a50e-4e697b47172g"))
}

///|
test "a failed turn names its cause, or says it failed" {
  fn failure(error : String) -> String? {
    reply_of("{\"type\":\"turn.failed\"\{error}}").failure
  }

  assert_eq(
    failure(",\"error\":{\"message\":\"rate limited\"}"),
    Some("rate limited"),
  )
  assert_eq(failure(",\"error\":{\"message\":429}"), Some("429"))
  assert_eq(failure(",\"error\":{\"code\":429}"), Some("null"))
  assert_eq(failure(",\"error\":\"text\""), Some("the turn failed"))
  assert_eq(failure(""), Some("the turn failed"))
}

///|
test "a verdict opens a line, after whitespace of any kind" {
  fn verdict(answer : String) -> String? {
    verdict_of(answer)
  }

  assert_eq(verdict("判定: LGTM\n対象: …"), Some("LGTM"))
  assert_eq(
    verdict("要約\n  判定:  修正必要\n以上"),
    Some("修正必要"),
  )
  assert_eq(verdict("判定:判定保留"), Some("判定保留"))
  assert_eq(verdict("要約\r\n判定: LGTM"), Some("LGTM"))
  assert_eq(verdict("要約\u{2028}判定: LGTM"), Some("LGTM"))
  assert_eq(verdict("要約\u{2029}\u{3000}判定:\u{3000}LGTM"), Some("LGTM"))
  assert_eq(verdict("x\n\u{FEFF}判定: LGTM"), Some("LGTM"))
  assert_eq(
    verdict("判定: 保留\n判定: 修正必要\n判定: LGTM"),
    Some("修正必要"),
  )
  assert_eq(verdict("\n\n判定:\n\nLGTM"), Some("LGTM"))
}

///|
test "text before the marker on its line, or a different word, is no verdict" {
  assert_eq(verdict_of(""), None)
  assert_eq(verdict_of("指摘はありません"), None)
  assert_eq(verdict_of("対象 判定: LGTM"), None)
  assert_eq(verdict_of("x \u{FEFF}判定: LGTM"), None)
  assert_eq(verdict_of("判定：LGTM"), None)
  assert_eq(verdict_of("判定: lgtm"), None)
  assert_eq(verdict_of("判定: 保留"), None)
  assert_eq(verdict_of("判定: "), None)
  assert_eq(verdict_of("判定:"), None)
}

///|
test "a first review picks the model and thinking and runs read-only in the checkout" {
  assert_eq(review_argv(None, "/repo", None, None), [
    "exec", "--json", "--sandbox", "read-only", "-C", "/repo", "-m", "gpt-6.1-sol",
    "-c", "model_reasoning_effort=\"medium\"", "-",
  ])
  assert_eq(review_argv(None, "/repo", Some("m"), Some("high")), [
    "exec", "--json", "--sandbox", "read-only", "-C", "/repo", "-m", "m", "-c", "model_reasoning_effort=\"high\"",
    "-",
  ])
  assert_eq(
    review_argv(None, "/repo", Some(""), Some("")),
    review_argv(None, "/repo", None, None),
  )
}

///|
test "a resumed review keeps the reviewer's own settings unless it is told others" {
  assert_eq(review_argv(Some(REVIEWER), "/repo", None, None), [
    "exec",
    "resume",
    REVIEWER,
    "--json",
    "-c",
    "sandbox_mode=\"read-only\"",
    "-",
  ])
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
test "an error repeats a child's output only as far as it names the cause" {
  assert_eq(detail("  boom \n\n"), "boom")
  assert_eq(detail(""), "")
  assert_eq(detail("あ".repeat(500)), "あ".repeat(500))
  assert_eq(detail("あ".repeat(600)), "あ".repeat(500))
  assert_eq(detail("a".repeat(498) + "😀tail"), "a".repeat(498) + "😀")
  assert_eq(detail("a".repeat(499) + "😀tail"), "a".repeat(499) + "\u{FFFD}")
}
