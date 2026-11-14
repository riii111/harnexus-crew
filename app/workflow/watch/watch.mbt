///|
/// Runs `watch` by passing each of its options to pr-wake as the subcommand it names.
/// Without an option, the long-running watch is handed to pr-wake's engine on this process's own stdio.
pub async fn watch(
  args : @workflow.WatchInput,
  env : @environment.Env,
  which~ : (String) -> String?,
) -> Json raise @failure.TaskFailed {
  @workflow.refuse_in_cloud(env, "watch")

  if args.release is Some(release) {
    return call_prwake(env, ["release", release])
  }

  if args.status {
    return call_prwake(env, ["status", "--json"])
  }

  if args.sender {
    return call_prwake(env, ["sender"])
  }

  if args.link is Some(link) {
    if !is_github_pr(link) {
      @failure.fail("\{link} is not watched: \{NOT_LINKABLE}")
    }

    // Without --take-over pr-wake refuses a PR another chat is watched for.
    return call_prwake(env, ["link", link])
  }

  if args.dry_run {
    let argv = ["dry-run"]

    for pr in args.prs {
      argv.push("--pr")
      argv.push(pr)
    }

    return call_prwake(env, argv)
  }

  @prwake.run_watch_engine(env, which~)
}

///|
async fn call_prwake(
  env : @environment.Env,
  args : Array[String],
) -> Json raise @failure.TaskFailed {
  Json::object(@prwake.call(env, args))
}
