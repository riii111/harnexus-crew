///|
const PROTOCOL_VERSION : Int32 = 1

///|
/// The bridge must answer first, so the timeout exceeds the longest wait_threads it allows.
const ANSWER_TIMEOUT_MS : Int32 = 900000

///|
const SOCKET_HINT : String = "open the app with HARNEXUS_CALL_SOCKET=on (for example `HARNEXUS_CALL_SOCKET=on bun run open-app` in the harnexus checkout) and run outside the sandbox"

///|
pub async fn call_app(
  env : @environment.Env,
  caller : String,
  tool : String,
  args : Map[String, Json],
  timeout_ms~ : Int32 = ANSWER_TIMEOUT_MS,
) -> CallAnswer noraise {
  let socket = @environment.resolve_caller_socket(env) catch {
    @failure.TaskFailed(message) => return not_sent(message)
  }
  let path = match socket {
    Some(path) => path
    None => return not_sent("the call socket is off (HARNEXUS_CALL_SOCKET=off)")
  }
  let line = Json::object({
    "version": Json::number(PROTOCOL_VERSION.to_double()),
    "threadId": Json::string(caller),
    "tool": Json::string(tool),
    "arguments": Json::object(args),
  }).stringify()
  let answer = @socket.exchange_line(path, line, timeout_ms) catch {
    @boundary.LineExchangeFailed(code~, connected~, message~, ..) => {
      let reason = code.unwrap_or(message)
      // A socket that could not be connected to never received the call; any other failure came after it was written.
      return if connected {
        unknown("no answer: \{reason}")
      } else {
        not_sent("\{path}: \{reason}; \{socket_hint(code)}")
      }
    }
  }
  answer_of(answer)
}

///|
fn socket_hint(code : String?) -> String {
  match code {
    Some("ENOENT") => "no bridge has opened the socket; \{SOCKET_HINT}"
    Some("ECONNREFUSED") =>
      "a bridge that has exited left the socket; the running bridge takes it over within seconds, so run again, and reopen the app if it persists"
    Some("EPERM") | Some("EACCES") =>
      "the sandbox blocked the connection; run outside the sandbox"
    _ => SOCKET_HINT
  }
}

///|
fn not_sent(error : String) -> CallAnswer {
  CallAnswer::failed(NotSent, error~)
}

///|
fn unsupported(error : String) -> CallAnswer {
  CallAnswer::failed(Unsupported, error~)
}

///|
fn unknown(error : String) -> CallAnswer {
  CallAnswer::failed(Unknown, error~)
}

///|
fn answer_of(line : String) -> CallAnswer {
  let parsed = @jsonio.parse(line) catch { _ => Json::null() }
  if parsed is Object(members) {
    // The version only frames the message, so remove it from the recorded answer.
    members.remove("version")
  }
  CallAnswer::of_json(parsed).unwrap_or(
    unknown("no answer: answer without outcome"),
  )
}
