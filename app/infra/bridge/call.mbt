///|
/// The bridge must answer first, so the timeout exceeds the longest wait_threads it allows.
const ANSWER_TIMEOUT_MS : Int32 = 900000

///|
const PROTOCOL_VERSION : Int32 = 1

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

      // After the connection the call may or may not have been written, so only a failure to connect leaves it unsent.
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
const SOCKET_HINT : String = "open the app with HARNEXUS_CALL_SOCKET=on (for example `HARNEXUS_CALL_SOCKET=on bun run open-app` in the harnexus checkout) and run outside the sandbox"

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
