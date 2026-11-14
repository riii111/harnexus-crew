///|
pub fn refuse_in_cloud(
  env : @environment.Env,
  command : String,
) -> Unit raise @failure.TaskFailed {
  match @environment.parse_declared_environment(env) {
    Some({ environment: Cloud, runner, }) => {
      let alternative = match runner {
        InCloud(Some(ClaudeCloud)) =>
          "In a Claude Code cloud session, start a worker as a new cloud session with create_session, and follow its PR with subscribe_pr_activity from that session"
        _ =>
          "Cloud cannot create or resume other tasks or threads from here; PR notifications are not built for Cloud, so check the PR with gh"
      }

      @failure.fail(
        "\{command} needs the Codex App and is unavailable in Cloud. \{alternative}",
      )
    }
    _ => ()
  }
}

///|
pub fn refuse_in_t3(
  env : @environment.Env,
  command : String,
  alternative : String,
) -> Unit raise @failure.TaskFailed {
  if @environment.app_of(env) is T3 {
    @failure.fail(
      "\{command} needs the Codex App and is unavailable in T3 Code. \{alternative}",
    )
  }
}

///|
pub fn require_home(env : @environment.Env) -> Unit raise @failure.TaskFailed {
  if env.get("HOME") is None {
    @failure.fail("HOME is not set")
  }
}
