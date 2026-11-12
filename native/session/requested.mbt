///|
/// Shows the session a request file belongs to, as flat fields.
pub async fn state_request(
  path : String,
  env : @environment.Env,
  which~ : (String) -> String?,
) -> Json raise @failure.TaskFailed {
  state_request_in(Context::of_env(env, which~), path)
}

///|
async fn state_request_in(
  ctx : Context,
  path : String,
) -> Json raise @failure.TaskFailed {
  @environment.refuse_in_cloud(ctx.env, "state --request")
  requested_session(ctx, path).show()
}

///|
/// Settles the send of a request that ended with a result nobody knows, as the user found it in the app.
pub async fn resolve(
  args : @args.ResolveArgs,
  env : @environment.Env,
  which~ : (String) -> String?,
) -> Json raise @failure.TaskFailed {
  resolve_in(Context::of_env(env, which~), args)
}

///|
async fn resolve_in(
  ctx : Context,
  args : @args.ResolveArgs,
) -> Json raise @failure.TaskFailed {
  @environment.refuse_in_cloud(ctx.env, "resolve")
  let thread = match named(args.thread_id) {
    Some(id) => Some(@request.chat_id(id, "--thread-id"))
    None => None
  }
  requested_session(ctx, args.request).resolve(args.sent, thread)
}

///|
/// The session of a request file, which is a launch or a review by what the file asks for.
async fn requested_session(
  ctx : Context,
  path : String,
) -> Session raise @failure.TaskFailed {
  let raw = read_json(path)
  if raw is Object(members) && members.contains("completionTarget") {
    let request = @request.LaunchRequest::from_json(raw, ctx.probe)
    return launch_session(ctx.env, ctx.ports, request)
  }
  let request = @request.ReviewRequest::from_json(
    raw,
    Worktrees(ctx.host.worktrees),
    ctx.probe,
    ctx.git,
  )
  let worker = @request.caller_id(ctx.env)
  review_session(
    ctx.env,
    ctx.ports,
    request.with_worker_chat_id(worker),
    worker,
  )
}
