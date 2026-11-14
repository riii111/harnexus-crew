///|
async test "refuse_in_cloud allows a command outside the Cloud" {
  let env = @testkit.env_of([("HOME", "/h")])

  assert_eq(@testkit.failure_of(() => refuse_in_cloud(env, "launch")), "")
}

///|
async test "refuse_in_cloud allows a command that is explicitly local" {
  let env = @testkit.env_of([
    ("HARNEXUS_EXECUTION_ENV", "local"),
    ("CODEX_ENVIRONMENT_ID", "e"),
  ])

  assert_eq(@testkit.failure_of(() => refuse_in_cloud(env, "launch")), "")
}

///|
async test "refuse_in_cloud points to gh in an explicit Cloud" {
  let env = @testkit.env_of([("HARNEXUS_EXECUTION_ENV", "cloud")])

  assert_eq(
    @testkit.failure_of(() => refuse_in_cloud(env, "launch")),
    "launch needs the Codex App and is unavailable in Cloud. Cloud cannot create or resume other tasks or threads from here; PR notifications are not built for Cloud, so check the PR with gh",
  )
}

///|
async test "refuse_in_cloud points to create_session in a Claude Code cloud session" {
  let env = @testkit.env_of([("CLAUDE_CODE_REMOTE", "true")])

  assert_eq(
    @testkit.failure_of(() => refuse_in_cloud(env, "launch")),
    "launch needs the Codex App and is unavailable in Cloud. In a Claude Code cloud session, start a worker as a new cloud session with create_session, and follow its PR with subscribe_pr_activity from that session",
  )
}

///|
async test "refuse_in_t3 refuses a command only the Codex App runs" {
  let env = @testkit.env_of([("T3CODE_THREAD_ID", "t")])

  assert_eq(
    @testkit.failure_of(() => refuse_in_t3(env, "cloud", "Use the App.")),
    "cloud needs the Codex App and is unavailable in T3 Code. Use the App.",
  )
}

///|
async test "refuse_in_t3 allows a command outside T3 Code" {
  let env = @testkit.env_of([])

  assert_eq(
    @testkit.failure_of(() => refuse_in_t3(env, "cloud", "Use the App.")),
    "",
  )
}
