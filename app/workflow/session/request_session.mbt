///|
/// Shows the session a request file belongs to, as flat fields.
pub async fn show_request_state(
  path : String,
  env : @environment.Env,
  which~ : (String) -> String?,
) -> Json raise @failure.TaskFailed {
  show_request_state_in(Context::of_env(env, which~), path)
}

///|
/// Settles the send of a request that ended with a result nobody knows, as the user found it in the app.
pub async fn resolve(
  args : @workflow.ResolveInput,
  env : @environment.Env,
  which~ : (String) -> String?,
) -> Json raise @failure.TaskFailed {
  resolve_in(Context::of_env(env, which~), args)
}

///|
async fn show_request_state_in(
  ctx : Context,
  path : String,
) -> Json raise @failure.TaskFailed {
  @workflow.refuse_in_cloud(ctx.env, "state --request")

  open_requested_session(ctx, path).show()
}

///|
async fn resolve_in(
  ctx : Context,
  args : @workflow.ResolveInput,
) -> Json raise @failure.TaskFailed {
  @workflow.refuse_in_cloud(ctx.env, "resolve")

  let thread = match @text.nonempty(args.thread_id) {
    Some(id) => Some(@request.check_chat_id(id, "--thread-id"))
    None => None
  }

  open_requested_session(ctx, args.request).resolve(args.sent, thread)
}

///|
/// The session of a request file, which is a launch or a review by what the file asks for.
async fn open_requested_session(
  ctx : Context,
  path : String,
) -> Session raise @failure.TaskFailed {
  let raw = @store.read_regular_json(path)
  if raw is Object(members) && members.contains("completionTarget") {
    let request = @request.LaunchRequest::from_json(raw, ctx.probe)
    return open_launch_session(ctx.env, ctx.ports, request)
  }

  let request = @request.ReviewRequest::from_json(
    raw,
    Worktrees(ctx.host.worktrees),
    ctx.probe,
    ctx.git,
  )
  let worker = @request.read_caller_id(ctx.env)
  open_review_session(
    ctx.env,
    ctx.ports,
    request.with_worker_chat_id(worker),
    worker,
  )
}
