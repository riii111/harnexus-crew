///|
/// Sends a worker's checkout to its reviewer, in a thread of its own the first time and to the same reviewer after.
/// `cloud` reviews when the worker runs in a Claude Code cloud session, which has no thread in an app.
pub async fn review(
  args : @workflow.ReviewInput,
  env : @environment.Env,
  which~ : (String) -> String?,
  cloud~ : async (@workflow.ReviewInput) -> Json raise @failure.TaskFailed,
) -> Json raise @failure.TaskFailed {
  review_in(Context::of_env(env, which~), args, cloud)
}

///|
/// A review session keeps the members named, so a request that differs in one of them starts a session of its own.
/// A Cloud review keeps fewer members than an app one, so the caller names them.
pub fn check_kept(
  previous : Json,
  current : Json,
  keys : Array[String],
) -> Unit raise @failure.TaskFailed {
  for key in keys {
    if resolve_session_value(previous, key) !=
      resolve_session_value(current, key) {
      @failure.fail("review session must keep the original \{key}")
    }
  }
}

///|
async fn review_in(
  ctx : Context,
  args : @workflow.ReviewInput,
  cloud : async (@workflow.ReviewInput) -> Json raise @failure.TaskFailed,
) -> Json raise @failure.TaskFailed {
  if @environment.declared_environment(ctx.env)
    is Some({ environment: Cloud, runner: InCloud(Some(ClaudeCloud)), }) {
    return cloud(args)
  }
  @workflow.refuse_in_cloud(ctx.env, "review")
  // In the app the reviewer is a chat of its own, which is asked there.
  if args.ask is Some(_) {
    @failure.fail("--ask applies to review only in a Claude Code cloud session")
  }
  if args.discard_pending {
    @failure.fail(
      "--recover applies to review only in a Claude Code cloud session",
    )
  }
  let request = read_review_request(ctx, args.request)
  let worker = @request.read_caller_id(ctx.env)
  let request = match request.worker_chat_id {
    None => request.with_worker_chat_id(worker)
    Some(id) if id == worker => request
    Some(_) =>
      @failure.fail(
        "workerChatId in the request must equal \{ctx.host.thread_variable}",
      )
  }
  let session = open_review_session(ctx.env, ctx.ports, request, worker)
  session.check_idle()
  let state = state_json(session.state)
  let recorded = @jsonio.field(state, "candidate")
  if truthy(recorded) && !(recorded is Object(_)) {
    @failure.fail("\{session.state_path} holds an invalid candidate")
  }
  let previous = match recorded {
    Object(members) if !members.is_empty() => Some(members)
    _ => None
  }
  let candidate = request.resolve_candidate(previous, args.update_base, ctx.git)
  let data = candidate.to_json()
  if previous is Some(previous) {
    check_kept(Json::object(previous), data, app_session_keys)
    if value_of(previous, "head") == @jsonio.field(data, "head") {
      @failure.fail(
        "head \{@jsonio.as_text(@jsonio.field(data, "head"))} was already sent to reviewer \{@jsonio.as_text(@jsonio.field(state, "reviewer"))}; wait for its result",
      )
    }
  }
  let fields = candidate.build_reviewer_fields(
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
    let thinking = match @text.nonempty(args.thinking) {
      Some(thinking) => Some(thinking)
      None => ctx.host.thinking.map(thinking => thinking.reviewer)
    }
    sent["target"] = Json::object({
      "type": Json::string("project"),
      "projectId": Json::string(project),
      "environment": Json::object({ "type": Json::string("local") }),
    })
    sent["title"] = Json::string(thread_title("Review", data))
    sent["model"] = Json::string(
      @text.nonempty(args.model).unwrap_or("gpt-6.1-sol"),
    )
    if thinking is Some(thinking) {
      sent["thinking"] = Json::string(thinking)
    }
    "create_thread"
  }
  session.send(worker, tool, sent, [
    ("candidate", data),
    ("workspace", @jsonio.field(data, "checkout")),
  ])
}

///|
async fn read_review_request(
  ctx : Context,
  path : String,
) -> @request.ReviewRequest raise @failure.TaskFailed {
  @request.ReviewRequest::from_json(
    @store.read_json(path),
    Worktrees(ctx.host.worktrees),
    ctx.probe,
    ctx.git,
  )
}

///|
fn open_review_session(
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
      if @jsonio.field(candidate, "workerChatId") is String(id) && id == thread {
        @failure.fail("a worker cannot review itself")
      }
      let previous = state_json(state)
      let settings = [
        sent_settings(sent),
        @jsonio.field(previous, "settings"),
        sent_settings(@jsonio.field(previous, "sent")),
      ]
      {
        "reviewer": Json::string(thread),
        "candidate": candidate,
        "sent": sent,
        "settings": first_set(settings),
      }
    },
    summarize=(state, pending) => {
      let candidate = @jsonio.field(state_json(state), "candidate")
      {
        "kind": Json::string("review"),
        "reviewerThreadId": @jsonio.field(state_json(state), "reviewer"),
        "workerThreadId": first_set([
          @jsonio.field(candidate, "workerChatId"),
          Json::string(worker),
        ]),
        "base": @jsonio.field(candidate, "base"),
        "head": @jsonio.field(candidate, "head"),
        "baseBranch": @jsonio.field(candidate, "baseBranch"),
        "prUrl": @jsonio.field(candidate, "prUrl"),
        "pendingHead": @jsonio.field(
          @jsonio.field(state_json(pending), "candidate"),
          "head",
        ),
      }
    },
  )
}

///|
/// A member of a request as the session compares it: the checkout by its real path.
fn resolve_session_value(request : Json, key : String) -> Json {
  let value = @jsonio.field(request, key)
  if key == "checkout" && truthy(value) {
    Json::string(@store.real_path_or_self(@jsonio.as_text(value)))
  } else {
    value
  }
}

///|
/// The members that make a review session the same session when a review is asked for again.
let app_session_keys : Array[String] = [
  "taskId", "workerAI", "workerChatId", "projectId", "checkout",
]

///|
fn first_set(values : Array[Json]) -> Json {
  for value in values {
    if !(value is Null) {
      return value
    }
  }
  Json::null()
}
