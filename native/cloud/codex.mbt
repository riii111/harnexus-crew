///|
const DEFAULT_TIMEOUT_MS : Int32 = 1800000

///|
const DEFAULT_KILL_GRACE_MS : Int32 = 5000

///|
const DEFAULT_MODEL : String = "gpt-6.1-sol"

///|
const DEFAULT_THINKING : String = "medium"

///|
const NO_ROLLOUT : String = "no rollout found"

///|
let recovery_hint : String = "its result is unknown, so it is not sent again on its own. Check the reviewer, then rerun with --recover discard to send the candidate again"

///|
/// How the Codex CLI is run: the program, and how long a run may last.
priv struct Launch {
  bin : String
  timeout_ms : Int32
  kill_grace_ms : Int32
}

///|
fn Launch::of_env(env : @environment.Env) -> Launch raise @failure.TaskFailed {
  {
    bin: configured_binary(env, "HARNEXUS_CODEX_BIN", "codex"),
    timeout_ms: milliseconds(
      env,
      "HARNEXUS_REVIEW_TIMEOUT_MS",
      DEFAULT_TIMEOUT_MS,
    ),
    kill_grace_ms: milliseconds(
      env,
      "HARNEXUS_REVIEW_KILL_GRACE_MS",
      DEFAULT_KILL_GRACE_MS,
    ),
  }
}

///|
fn configured_binary(
  env : @environment.Env,
  name : String,
  fallback : String,
) -> String raise @failure.TaskFailed {
  match env.get_nonempty(name) {
    None => fallback
    Some(path) =>
      if path.has_prefix("/") {
        path
      } else {
        @failure.fail("\{name} must be an absolute path")
      }
  }
}

///|
/// A positive whole number of milliseconds of at most ten digits.
/// A value a 32-bit timer cannot hold counts as the longest it can.
fn milliseconds(
  env : @environment.Env,
  name : String,
  fallback : Int32,
) -> Int32 raise @failure.TaskFailed {
  guard env.get_nonempty(name) is Some(value) else { return fallback }
  let digits = value.code_units()
  let valid = digits.length() >= 1 &&
    digits.length() <= 10 &&
    digits[0] != '0' &&
    digits.iter().all(unit => unit >= '0' && unit <= '9')
  guard valid else {
    @failure.fail("\{name} must be a positive number of milliseconds")
  }
  let mut total : Int64 = 0
  for unit in digits {
    total = total * 10L + (unit.to_int() - 48).to_int64()
  }
  if total > 2147483647L {
    2147483647
  } else {
    total.to_int()
  }
}

///|
/// What a Codex CLI run said on its JSON event lines: the thread it ran, the last message it finished, and how a failed turn ended.
priv struct Reply {
  mut thread_id : String?
  mut answer : String?
  mut failure : String?
}

///|
fn reply_of(stdout : String) -> Reply {
  let reply : Reply = { thread_id: None, answer: None, failure: None, }
  // codex exec --json prints one event per line: the thread it runs, each item, and how the turn ended.
  for line in stdout.split("\n") {
    let parsed = Ok(@jsonio.parse(line.to_owned())) catch {
      failed => Err(failed)
    }
    guard parsed is Ok(Object(event)) else { continue }
    match event.get("type") {
      Some(String("thread.started")) =>
        if event.get("thread_id") is Some(String(id)) {
          reply.thread_id = if is_thread_id(id) { Some(id) } else { None }
        }
      Some(String("item.completed")) =>
        if event.get("item") is Some(Object(item)) &&
          item.get("type") is Some(String("agent_message")) &&
          item.get("text") is Some(String(text)) {
          reply.answer = Some(text)
        }
      Some(String("turn.failed")) =>
        reply.failure = Some(
          match event.get("error") {
            Some(Object(error)) =>
              as_text(error.get("message").unwrap_or(Json::null()))
            _ => "the turn failed"
          },
        )
      _ => ()
    }
  }
  reply
}

///|
/// A Codex thread ID is a lower-case UUID.
fn is_thread_id(text : String) -> Bool {
  let units = text.code_units()
  if units.length() != 36 {
    return false
  }
  for index, unit in units {
    let ok = match index {
      8 | 13 | 18 | 23 => unit == '-'
      _ => (unit >= '0' && unit <= '9') || (unit >= 'a' && unit <= 'f')
    }
    if !ok {
      return false
    }
  }
  true
}

///|
/// The arguments of a review run: a new reviewer for the first head, the same reviewer resumed after.
fn review_argv(
  reviewer : String?,
  checkout : String,
  model : String?,
  thinking : String?,
) -> Array[String] {
  // An empty value falls back like a missing one, as for a reviewer chat in the app.
  let chosen_model = match named(model) {
    None if reviewer is None => Some(DEFAULT_MODEL)
    other => other
  }
  let chosen_thinking = match named(thinking) {
    None if reviewer is None => Some(DEFAULT_THINKING)
    other => other
  }
  let chosen = []
  if chosen_model is Some(model) {
    chosen.push("-m")
    chosen.push(model)
  }
  if chosen_thinking is Some(thinking) {
    chosen.push("-c")
    chosen.push(
      "model_reasoning_effort=\{@jsonio.stringify(Json::string(thinking))}",
    )
  }
  // The reviewer only reads; resume has no --sandbox or --cd, so it takes the setting and runs in the checkout.
  let argv = match reviewer {
    None => ["exec", "--json", "--sandbox", "read-only", "-C", checkout]
    Some(id) =>
      ["exec", "resume", id, "--json", "-c", "sandbox_mode=\"read-only\""]
  }
  argv.append(chosen)
  argv.push("-")
  argv
}

///|
/// The arguments of a question put to a reviewer that exists.
fn ask_argv(reviewer : String) -> Array[String] {
  [
    "exec", "resume", reviewer, "--json", "-c", "sandbox_mode=\"read-only\"", "-",
  ]
}

///|
fn named(value : String?) -> String? {
  match value {
    Some("") | None => None
    other => other
  }
}

///|
fn stop_reason(ended : @boundary.ProcessEnd) -> String {
  match ended {
    Timeout => "timeout"
    _ => "output over the limit"
  }
}

///|
/// The verdict line a reviewer's answer opens a section with: `判定: LGTM`, `判定: 修正必要` or `判定: 判定保留`.
/// A line may be indented, and the first one that names a verdict counts.
fn verdict_of(answer : String) -> String? {
  let units = answer.code_units()
  let marker = "判定:".code_units()
  let mut at = 0
  while at + marker.length() <= units.length() {
    if matches_at(units, at, marker) && starts_a_line(units, at) {
      let after = skip_whitespace(units, at + marker.length())
      for word in ["LGTM", "修正必要", "判定保留"] {
        if matches_at(units, after, word.code_units()) {
          return Some(word)
        }
      }
    }
    at += 1
  }
  None
}

///|
fn matches_at(
  units : ArrayView[UInt16],
  at : Int32,
  word : ArrayView[UInt16],
) -> Bool {
  if at + word.length() > units.length() {
    return false
  }
  for index in 0..<word.length() {
    if units[at + index] != word[index] {
      return false
    }
  }
  true
}

///|
/// Whether only whitespace lies between the marker and the start of its line, as `^\s*` does with the `m` flag.
fn starts_a_line(units : ArrayView[UInt16], at : Int32) -> Bool {
  let mut back = at
  while back > 0 && is_whitespace(units[back - 1]) {
    back -= 1
    if is_line_end(units[back]) {
      return true
    }
  }
  back == 0
}

///|
fn skip_whitespace(units : ArrayView[UInt16], from : Int32) -> Int32 {
  let mut at = from
  while at < units.length() && is_whitespace(units[at]) {
    at += 1
  }
  at
}

///|
fn is_whitespace(unit : UInt16) -> Bool {
  @text.has_js_whitespace(unit.to_int().unsafe_to_char().to_string())
}

///|
fn is_line_end(unit : UInt16) -> Bool {
  unit == '\n' || unit == '\r' || unit == 0x2028 || unit == 0x2029
}

///|
fn as_text(value : Json) -> String {
  match value {
    String(text) => text
    other => @jsonio.stringify(other)
  }
}

///|
/// A child's output is repeated in an error only as far as it names the cause: the trimmed text up to 500 UTF-16 units.
fn detail(text : String) -> String {
  let trimmed = @text.js_trim(text)
  if trimmed.length() <= 500 {
    return trimmed
  }
  // A cut through a surrogate pair leaves half of it, which the output shows as U+FFFD.
  if trimmed.code_unit_at(499).to_int() is (0xD800..<=0xDBFF) {
    "\{trimmed[:499]}\u{FFFD}"
  } else {
    trimmed[:500].to_owned()
  }
}
