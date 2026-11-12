///|
/// Sends a worker's checkout to its reviewer, in a thread of its own the first time and to the same reviewer after.
/// `cloud` reviews when the worker runs in a Claude Code cloud session, which has no thread in an app.
pub async fn review(
  args : @args.ReviewArgs,
  env : @environment.Env,
  which~ : (String) -> String?,
  cloud~ : async (@args.ReviewArgs) -> Json raise @failure.TaskFailed,
) -> Json raise @failure.TaskFailed {
  review_in(Context::of_env(env, which~), args, cloud)
}

///|
async fn review_in(
  ctx : Context,
  args : @args.ReviewArgs,
  cloud : async (@args.ReviewArgs) -> Json raise @failure.TaskFailed,
) -> Json raise @failure.TaskFailed {
  if @environment.declared_environment(ctx.env)
    is Some({ environment: Cloud, runner: InCloud(Some(ClaudeCloud)), .. }) {
    return cloud(args)
  }
  @environment.refuse_in_cloud(ctx.env, "review")
  // In the app the reviewer is a chat of its own, which is asked there.
  if args.ask is Some(_) {
    @failure.fail("--ask applies to review only in a Claude Code cloud session")
  }
  if args.recover is Some(_) {
    @failure.fail(
      "--recover applies to review only in a Claude Code cloud session",
    )
  }
  let request = review_request_of(ctx, args.request)
  let worker = @request.caller_id(ctx.env)
  let request = match request.worker_chat_id {
    None => request.with_worker_chat_id(worker)
    Some(String(id)) if id == worker => request
    Some(_) =>
      @failure.fail(
        "workerChatId in the request must equal \{ctx.host.thread_variable}",
      )
  }
  let session = review_session(ctx.env, ctx.ports, request, worker)
  session.check_idle()
  let state = state_json(session.state)
  let recorded = field(state, "candidate")
  if truthy(recorded) && !(recorded is Object(_)) {
    @failure.fail("\{session.state_path} holds an invalid candidate")
  }
  let previous = match recorded {
    Object(members) if !members.is_empty() => Some(members)
    _ => None
  }
  let candidate = request.candidate(previous, args.update_base, ctx.git)
  let data = candidate.to_json()
  if previous is Some(previous) {
    check_kept(Json::object(previous), data, app_session_keys)
    if json_equal(value_of(previous, "head"), field(data, "head")) {
      @failure.fail(
        "head \{as_text(field(data, "head"))} was already sent to reviewer \{as_text(field(state, "reviewer"))}; wait for its result",
      )
    }
  }
  let fields = candidate.reviewer_fields(
    (ctx.host.reply_to)(request.worker_ai.name()),
    ctx.probe,
  )
  let prompt = (ctx.prompt)(Reviewer, fields)
  let sent : Map[String, Json] = { "prompt": Json::string(prompt) }
  let tool = if session.state is Some(kept) {
    sent["threadId"] = value_of(kept, "reviewer")
    if args.model is Some(model) {
      sent["model"] = Json::string(model)
    }
    if args.thinking is Some(thinking) {
      sent["thinking"] = Json::string(thinking)
    }
    "send_message_to_thread"
  } else {
    let project = (ctx.review_project)(worker)
    let thinking = match named(args.thinking) {
      Some(thinking) => Some(thinking)
      None => ctx.host.thinking.map(thinking => thinking.reviewer)
    }
    sent["target"] = Json::object({
      "type": Json::string("project"),
      "projectId": Json::string(project),
      "environment": Json::object({ "type": Json::string("local") }),
    })
    sent["title"] = Json::string(thread_title("Review", data))
    sent["model"] = Json::string(named(args.model).unwrap_or("gpt-6.1-sol"))
    if thinking is Some(thinking) {
      sent["thinking"] = Json::string(thinking)
    }
    "create_thread"
  }
  session.send(worker, tool, sent, [
    ("candidate", data),
    ("workspace", field(data, "checkout")),
  ])
}

///|
/// Reads and checks a review request: its checkout must be a worker's worktree of the app.
async fn review_request_of(
  ctx : Context,
  path : String,
) -> @request.ReviewRequest raise @failure.TaskFailed {
  @request.ReviewRequest::from_json(
    read_json(path),
    Worktrees(ctx.host.worktrees),
    ctx.probe,
    ctx.git,
  )
}

///|
/// The session of a review, kept per checkout and worker chat.
fn review_session(
  env : @environment.Env,
  ports : Ports,
  request : @request.ReviewRequest,
  worker : String,
) -> Session raise @failure.TaskFailed {
  let directory = @store.state_directory(
    env.state_root(),
    "review",
    request.session_key(worker),
  )
  Session::open(
    directory,
    ports,
    confirmed=(thread, pending, sent, state) => {
      if state is Some(kept) &&
        !(value_of(kept, "reviewer") is String(reviewer) && reviewer == thread) {
        @failure.fail("review session must keep the same reviewer")
      }
      let candidate = value_of(pending, "candidate")
      if field(candidate, "workerChatId") is String(id) && id == thread {
        @failure.fail("a worker cannot review itself")
      }
      let state_json = state_json(state)
      let settings = [
        sent_settings(sent),
        field(state_json, "settings"),
        sent_settings(field(state_json, "sent")),
      ]
      {
        "reviewer": Json::string(thread),
        "candidate": candidate,
        "sent": sent,
        "settings": first_set(settings),
      }
    },
    summarize=(state, pending) => {
      let candidate = field(state_json(state), "candidate")
      {
        "kind": Json::string("review"),
        "reviewerThreadId": field(state_json(state), "reviewer"),
        "workerThreadId": first_set([
          field(candidate, "workerChatId"),
          Json::string(worker),
        ]),
        "base": field(candidate, "base"),
        "head": field(candidate, "head"),
        "baseBranch": field(candidate, "baseBranch"),
        "prUrl": field(candidate, "prUrl"),
        "pendingHead": field(field(state_json(pending), "candidate"), "head"),
      }
    },
  )
}

///|
/// The first value that is not null, as `a ?? b ?? c` picks it.
fn first_set(values : Array[Json]) -> Json {
  for value in values {
    if !(value is Null) {
      return value
    }
  }
  Json::null()
}

///|
/// The members that make a review session the same session when a review is asked for again.
let app_session_keys : Array[String] = [
  "taskId", "workerAI", "workerChatId", "projectId", "checkout",
]

///|
/// A review session keeps the members named, so a request that differs in one of them starts a session of its own.
/// A Cloud review keeps fewer members than an app one, so the caller names them.
pub fn check_kept(
  previous : Json,
  current : Json,
  keys : Array[String],
) -> Unit raise @failure.TaskFailed {
  for key in keys {
    if !json_equal(session_value(previous, key), session_value(current, key)) {
      @failure.fail("review session must keep the original \{key}")
    }
  }
}

///|
/// A member of a request as the session compares it: the checkout by its real path.
fn session_value(request : Json, key : String) -> Json {
  let value = field(request, key)
  if key == "checkout" && truthy(value) {
    Json::string(@store.real_path_or_self(as_text(value)))
  } else {
    value
  }
}
