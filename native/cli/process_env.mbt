///|
/// The environment this process was started with.
pub fn process_env() -> @environment.Env {
  @environment.Env::new(@env.get_env_vars())
}

///|
fn require_home(env : @environment.Env) -> Unit raise @failure.TaskFailed {
  if env.get("HOME") is None {
    @failure.fail("HOME is not set")
  }
}
