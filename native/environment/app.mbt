///|
pub enum App {
  Codex
  T3
}

///|
pub fn App::name(self : App) -> String {
  match self {
    Codex => "codex"
    T3 => "t3"
  }
}

///|
pub const T3_THREAD_VARIABLE : String = "T3CODE_THREAD_ID"

///|
pub const CODEX_THREAD_VARIABLE : String = "CODEX_THREAD_ID"

///|
/// T3 Code sets its thread for every agent and job it starts, and runs Codex there with a thread ID of Codex's own, so its variable decides first.
pub fn app_of(env : Env) -> App {
  match env.get_nonempty(T3_THREAD_VARIABLE) {
    Some(_) => T3
    None => Codex
  }
}

///|
pub fn thread_variable(app : App) -> String {
  match app {
    Codex => CODEX_THREAD_VARIABLE
    T3 => T3_THREAD_VARIABLE
  }
}

///|
pub fn refuse_in_t3(
  env : Env,
  command : String,
  alternative : String,
) -> Unit raise @failure.TaskFailed {
  if app_of(env) is T3 {
    @failure.fail(
      "\{command} needs the Codex App and is unavailable in T3 Code. \{alternative}",
    )
  }
}
