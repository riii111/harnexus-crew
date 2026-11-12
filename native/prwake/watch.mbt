///|
/// Runs `watch` by passing each of its options to pr-wake as the subcommand it names.
/// Without an option, the long-running watch is handed to pr-wake's engine on this process's own stdio.
pub async fn watch(
  args : @args.WatchArgs,
  env : @environment.Env,
  which~ : (String) -> String?,
) -> Json raise @failure.TaskFailed {
  @environment.refuse_in_cloud(env, "watch")
  if args.release is Some(release) {
    return Json::object(call(env, ["release", release]))
  }
  if args.status {
    return Json::object(call(env, ["status", "--json"]))
  }
  if args.sender {
    return Json::object(call(env, ["sender"]))
  }
  if args.link is Some(link) {
    if !is_github_pr(link) {
      @failure.fail("\{link} is not watched: \{NOT_LINKABLE}")
    }
    // Without --take-over pr-wake refuses a PR another chat is watched for.
    return Json::object(call(env, ["link", link]))
  }
  if args.dry_run {
    let argv = ["dry-run"]
    for pr in args.prs {
      argv.push("--pr")
      argv.push(pr)
    }
    return Json::object(call(env, argv))
  }
  hand_over(env, which~)
}

///|
async fn hand_over(
  env : @environment.Env,
  which~ : (String) -> String?,
) -> Json raise @failure.TaskFailed {
  let engine = engine_of(env, which~)
  let exited = @process.run_inherited(engine, ["watch"], env.to_map()) catch {
    @boundary.CommandFailed(message~, ..) => @failure.fail(message)
  }
  if exited != 0 {
    @failure.fail("\{engine} watch exited with \{exited}")
  }
  { "watch": "stopped" }
}
