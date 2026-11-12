///|
const SOCKET_PROBE_TIMEOUT_MS : Int32 = 1500

///|
async fn environment_command(
  env : @environment.Env,
) -> Json raise @failure.TaskFailed {
  let detected = match @environment.detect(env) {
    Settled(declared) => declared
    AskSocket(path) =>
      if socket_accepts(path) {
        @environment.Detected::socket_accepted()
      } else {
        @environment.Detected::undetermined()
      }
    NothingToAsk => @environment.Detected::undetermined()
  }
  detected.to_json()
}

///|
async fn socket_accepts(path : String) -> Bool noraise {
  try {
    ignore(@socket.exchange_line(path, "", SOCKET_PROBE_TIMEOUT_MS))
    true
  } catch {
    _ => false
  }
}
