///|
/// Starts the worker of a task in a thread of its own, once: running it again for the same task and request finds the worker it started.
pub async fn launch(
  args : @workflow.LaunchInput,
  env : @environment.Env,
  which~ : (String) -> String?,
) -> Json raise @failure.TaskFailed {
  launch_in(Context::of_env(env, which~), args)
}

///|
async fn launch_in(
  ctx : Context,
  args : @workflow.LaunchInput,
) -> Json raise @failure.TaskFailed {
  @workflow.refuse_in_cloud(ctx.env, "launch")
  let request = @request.LaunchRequest::from_json(
    @store.read_json(args.request),
    ctx.probe,
  )
  let data = request.to_json()
  let session = open_launch_session(ctx.env, ctx.ports, request)
  if session.state is Some(state) {
    if !same_task(value_of(state, "request"), data) {
      @failure.fail(
        "\{request.task_id} already has worker \{@jsonio.as_text(value_of(state, "threadId"))} launched with a different request",
      )
    }
    return Json::object({
      "existing": value_of(state, "threadId"),
      "state": Json::string(session.state_path),
    })
  }
  let environment : Map[String, Json] = { "type": Json::string("worktree") }
  let target : Map[String, Json] = {
    "type": Json::string("project"),
    "projectId": Json::string(request.project_id),
    "environment": Json::object(environment),
  }
  if request.starting_branch is Text(branch) && branch != "" {
    environment["startingState"] = Json::object({
      "type": Json::string("branch"),
      "branchName": Json::string(branch),
    })
  }
  let fields = request.build_worker_fields(ctx.probe)
  let prompt = (ctx.prompt)(Worker, fields)
  let thinking = match @text.nonempty(args.thinking) {
    Some(thinking) => Some(thinking)
    None => ctx.host.thinking.map(thinking => thinking.worker)
  }
  let sent : Map[String, Json] = {
    "prompt": Json::string(prompt),
    "target": Json::object(target),
    "title": Json::string(thread_title("Impl", data)),
    "model": Json::string(
      @text.nonempty(args.model).unwrap_or("claude-sonnet-5-5"),
    ),
  }
  if thinking is Some(thinking) {
    sent["thinking"] = Json::string(thinking)
  }
  let caller = @request.read_caller_id(ctx.env)
  session.send(caller, "create_thread", sent, [
    ("request", data),
    ("workspace", Json::object(target)),
  ])
}

///|
fn open_launch_session(
  env : @environment.Env,
  ports : Ports,
  request : @request.LaunchRequest,
) -> Session raise @failure.TaskFailed {
  let directory = @store.state_directory(
    env.state_root(),
    "launch",
    request.session_key(),
  )
  Session::open(
    directory,
    ports,
    confirmed=(thread, pending, sent, _) => {
      "threadId": Json::string(thread),
      "request": value_of(pending, "request"),
      "sent": sent,
    },
    summarize=(state, _) => {
      "kind": Json::string("launch"),
      // The session is kept per task, so its request names the task before anything was sent.
      "taskId": Json::string(request.task_id),
      "workerThreadId": @jsonio.field(state_json(state), "threadId"),
    },
  )
}

///|
fn same_task(recorded : Json, data : Json) -> Bool {
  // To avoid starting another worker after a rename, exclude the display name from identity checks.
  recorded is Object(_) && without_name(recorded) == without_name(data)
}

///|
fn without_name(request : Json) -> Json {
  match request {
    Object(members) => {
      let kept : Map[String, Json] = Map([])
      for key, item in members {
        if key != "displayName" {
          kept[key] = item
        }
      }
      Json::object(kept)
    }
    other => other
  }
}
