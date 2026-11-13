///|
fn env_of(pairs : Array[(String, String)]) -> @environment.Env {
  @environment.Env::new(Map::from_array(pairs))
}

///|
fn cloud_refusal(pairs : Array[(String, String)]) -> String {
  try {
    refuse_in_cloud(env_of(pairs), "launch")
    "ok"
  } catch {
    @failure.TaskFailed(message) => message
  }
}

///|
test "Cloud refusals point to what the Cloud allows" {
  inspect(cloud_refusal([("HOME", "/h")]), content="ok")
  inspect(
    cloud_refusal([("HARNEXUS_EXECUTION_ENV", "cloud")]),
    content="launch needs the Codex App and is unavailable in Cloud. Cloud cannot create or resume other tasks or threads from here; PR notifications are not built for Cloud, so check the PR with gh",
  )
  inspect(
    cloud_refusal([("CLAUDE_CODE_REMOTE", "true")]),
    content="launch needs the Codex App and is unavailable in Cloud. In a Claude Code cloud session, start a worker as a new cloud session with create_session, and follow its PR with subscribe_pr_activity from that session",
  )
  inspect(
    cloud_refusal([
      ("HARNEXUS_EXECUTION_ENV", "local"),
      ("CODEX_ENVIRONMENT_ID", "e"),
    ]),
    content="ok",
  )
}

///|
test "T3 Code refuses what only the Codex App does" {
  let refused = try {
    refuse_in_t3(env_of([("T3CODE_THREAD_ID", "t")]), "cloud", "Use the App.")
    "ok"
  } catch {
    @failure.TaskFailed(message) => message
  }
  inspect(
    refused,
    content="cloud needs the Codex App and is unavailable in T3 Code. Use the App.",
  )
  refuse_in_t3(env_of([]), "cloud", "Use the App.")
}
