///|
const SOCKET_PROBE_TIMEOUT_MS : Int32 = 1500

///|
async fn environment_command(env : @environment.Env) -> Json {
  let detected = match @environment.detect(env) {
    Settled(declared) => declared
    AskSocket(path) => {
      require_home(env)
      if socket_accepts(path) {
        @environment.Detected::socket_accepted()
      } else {
        @environment.Detected::undetermined()
      }
    }
    NothingToAsk => {
      require_home(env)
      @environment.Detected::undetermined()
    }
  }
  detected.to_json()
}

///|
/// Only the socket step needs the home directory, which is where the TypeScript build first asks for it.
fn require_home(env : @environment.Env) -> Unit raise {
  if !env.home_known() {
    raise HomeNotFound
  }
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
