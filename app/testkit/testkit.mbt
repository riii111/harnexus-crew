///|
pub fn env_of(pairs : Array[(String, String)]) -> @environment.Env {
  @environment.Env::new(Map::from_array(pairs))
}

///|
/// The message `body` fails with, or "" when it succeeds.
pub async fn failure_of(
  body : async () -> Unit raise @failure.TaskFailed,
) -> String {
  try {
    body()
    ""
  } catch {
    failed => failed.message()
  }
}
