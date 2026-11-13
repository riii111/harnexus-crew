///|
priv enum CallSocketSetting {
  Off
  Default
  At(String)
}

///|
pub fn harnexus_state_path(env : Env) -> String raise @failure.TaskFailed {
  match env.get("HARNEXUS_STATE_PATH") {
    None | Some("") =>
      @path.join([env.home(), ".local/state/harnexus/threads.json"])
    Some(path) if @path.is_absolute(path) => path
    Some(_) => @failure.fail("HARNEXUS_STATE_PATH must be an absolute path")
  }
}

///|
/// Where a caller sends, or None when the socket is turned off, so a caller can say so instead of failing to connect.
pub fn caller_socket(env : Env) -> String? raise @failure.TaskFailed {
  match call_socket_setting(env) {
    Off => None
    At(_) | Default => Some(call_socket_path(env))
  }
}

///|
/// Where the bridge's call socket is, even when the setting turns it off, for a probe that only asks whether a bridge runs.
fn call_socket_path(env : Env) -> String raise @failure.TaskFailed {
  match call_socket_setting(env) {
    At(path) => path
    Off | Default =>
      @path.join([@path.dirname(harnexus_state_path(env)), "call.sock"])
  }
}

///|
/// Read as the harnexus bridge reads it, so a value the bridge refuses is refused here too.
fn call_socket_setting(
  env : Env,
) -> CallSocketSetting raise @failure.TaskFailed {
  match env.get("HARNEXUS_CALL_SOCKET") {
    None | Some("") | Some("on") => Default
    Some("off") => Off
    Some(path) if @path.is_absolute(path) => At(path)
    Some(_) =>
      @failure.fail("HARNEXUS_CALL_SOCKET must be on, off or an absolute path")
  }
}
