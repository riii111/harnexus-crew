///|
/// The environment this process was started with.
pub fn process_env() -> Env {
  Env::new(@env.get_env_vars())
}
