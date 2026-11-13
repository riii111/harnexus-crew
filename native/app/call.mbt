///|
const PROTOCOL_VERSION : Int32 = 1

///|
/// Longer than the longest wait_threads the bridge allows, so the bridge always answers first.
const ANSWER_TIMEOUT_MS : Int32 = 900000

///|
const QUERY_TIMEOUT_MS : Int32 = 10000

///|
const SOCKET_HINT : String = "open the app with HARNEXUS_CALL_SOCKET=on (for example `HARNEXUS_CALL_SOCKET=on bun run open-app` in the harnexus checkout) and run outside the sandbox"

///|
/// Asks the bridge for protocol 1 and sends the call only once the bridge offers the tool, so an older bridge never receives a write.
/// An older bridge answers the query as invalid, which is taken as unsupported; the first protocol is never tried instead.
pub async fn call_app(
  env : @environment.Env,
  caller : String,
  tool : String,
  args : Map[String, Json],
  timeout_ms~ : Int32 = ANSWER_TIMEOUT_MS,
) -> @call.CallAnswer noraise {
  let socket = @environment.caller_socket(env) catch {
    @failure.TaskFailed(message) => return not_sent(message)
  }
  let path = match socket {
    Some(path) => path
    None => return not_sent("the call socket is off (HARNEXUS_CALL_SOCKET=off)")
  }
  let query = @socket.exchange_line(
    path,
    @jsonio.stringify(
      Json::object({
        "version": Json::number(PROTOCOL_VERSION.to_double()),
        "query": Json::string("capabilities"),
      }),
    ),
    QUERY_TIMEOUT_MS,
  ) catch {
    // The query changes nothing, so any failure of it leaves the call unsent.
    @boundary.LineExchangeFailed(code~, message~, ..) =>
      return not_sent(
        "\{path}: \{code.unwrap_or(message)}; \{socket_hint(code)}",
      )
  }
  let operations = match offered_operations(query) {
    Some(operations) => operations
    None =>
      return unsupported(
        "the bridge does not offer call protocol \{PROTOCOL_VERSION}; update harnexus and restart the app",
      )
  }
  if !operations.contains(Json::string(tool)) {
    return unsupported("the bridge does not offer \{tool}")
  }
  let line = @jsonio.stringify(
    Json::object({
      "version": Json::number(PROTOCOL_VERSION.to_double()),
      "threadId": Json::string(caller),
      "tool": Json::string(tool),
      "arguments": Json::object(args),
    }),
  )
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
fn not_sent(error : String) -> @call.CallAnswer {
  @call.CallAnswer::failed(NotSent, error~)
}

///|
fn unsupported(error : String) -> @call.CallAnswer {
  @call.CallAnswer::failed(Unsupported, error~)
}

///|
fn unknown(error : String) -> @call.CallAnswer {
  @call.CallAnswer::failed(Unknown, error~)
}

///|
/// None unless the line is a bridge's `done` answer for protocol 1 that lists its operations.
fn offered_operations(line : String) -> Array[Json]? {
  let offered = @jsonio.parse(line) catch { _ => return None }
  guard offered is Object(members) else { return None }
  guard members.get("outcome") is Some(String("done")) else { return None }
  guard members.get("version") is Some(Number(version, ..)) &&
    version == PROTOCOL_VERSION.to_double() else {
    return None
  }
  match members.get("operations") {
    Some(Array(operations)) => Some(operations)
    _ => None
  }
}

///|
/// The version only frames the line, so the records keep the answer as the first protocol gave it.
fn answer_of(line : String) -> @call.CallAnswer {
  let without_outcome = unknown("no answer: answer without outcome")
  let parsed = @jsonio.parse(line) catch { _ => return without_outcome }
  guard parsed is Object(members) else { return without_outcome }
  guard members.get("outcome") is Some(String(_)) else {
    return without_outcome
  }
  let rest = Map([])
  for name, item in members {
    if name != "version" {
      rest[name] = item
    }
  }
  @call.CallAnswer::of_json(Json::object(rest)) catch {
    _ => without_outcome
  }
}
