///|
/// Links the worker's PR to its thread, so the PR's activity wakes the worker, and shows the PR in the thread's title.
pub async fn name(
  args : @workflow.NameInput,
  env : @environment.Env,
  which~ : (String) -> String?,
) -> Json raise @failure.TaskFailed {
  name_in(Context::of_env(env, which~), args)
}

///|
async fn name_in(
  ctx : Context,
  args : @workflow.NameInput,
) -> Json raise @failure.TaskFailed {
  @workflow.refuse_in_cloud(ctx.env, "name")
  guard @watch.github_pr_number(args.pr) is Some(number) else {
    @failure.fail("\{args.pr} is not watched: \{@watch.NOT_LINKABLE}")
  }

  let worker = @request.read_caller_id(ctx.env)
  // A worker the owner started by hand must still be watched, so the PR is linked first and for any chat.
  // The latest worker on a PR is the one doing it, so a worker naming its PR takes it over.
  let linked = (ctx.pr_wake)(["link", args.pr, "--take-over"])
  let watched = match linked.get("watched") {
    Some(String(watched)) => Some(watched)
    _ => None
  }

  let request = if ctx.host.renames_threads {
    find_launch_request(ctx.env, worker)
  } else {
    None
  }

  // Another chat keeps its own title, so only a launched worker is renamed.
  // The title must still read as the task while a search for the PR finds the worker, so the number goes last.
  let title = request.map(request => {
    "\{thread_title("Impl", request)} PR#\{number}"
  })

  let answer = match title {
    Some(title) =>
      Some(
        (ctx.ports.call)(worker, "name_thread", { "name": Json::string(title) }),
      )
    None => None
  }

  let renamed = answer.map(answer => answer.outcome == "done").unwrap_or(true)
  let applied_title = if renamed { title } else { None }

  // A PR the watch cannot see must never be taken as watched, so this fails even after a rename.
  guard watched is Some(watched) else {
    let renamed_as = match applied_title {
      Some(title) => " (the thread is named \{title})"
      None => ""
    }

    @failure.fail(
      "\{args.pr} is not watched\{renamed_as}: \{@watch.NOT_LINKABLE}",
    )
  }

  let shown : Map[String, Json] = {
    "threadId": Json::string(worker),
    "title": applied_title
    .map(title => Json::string(title))
    .unwrap_or(Json::null()),
    "watched": Json::string(watched),
  }

  // The PR stays watched when the app did not apply the rename, so the result says so rather than failing.
  if !renamed {
    let applied = answer
      .map(answer => answer.to_json().stringify())
      .unwrap_or("null")
    shown["renameError"] = Json::string(
      "name_thread was not applied: \{applied}",
    )
  }

  // The link alone would show a chat nothing can send to as watched, so the warning pr-wake gives for it is passed on.
  if linked.get("warning") is Some(String(warning)) {
    shown["warning"] = Json::string(warning)
  }

  Json::object(shown)
}

///|
fn find_launch_request(
  env : @environment.Env,
  thread : String,
) -> Json? raise @failure.TaskFailed {
  // A worker is never told the request's path, so its launch is found from the thread it runs in.
  let root = @path.join([env.state_root(), "launch"])
  let keys = list_directory_names(root)
  keys.sort_by(String::lexical_compare)

  for key in keys {
    let directory = @path.join([root, key])
    if !@store.is_directory(directory) {
      continue
    }

    // Another task's unreadable state must not stop every worker from finding its own, so it is skipped.
    let state = @store.read_json_or_null(@path.join([directory, "state.json"])) catch {
      _ => Json::null()
    }

    if state is Object(members) &&
      members.get("threadId") is Some(String(id)) &&
      id == thread &&
      members.get("request") is Some(Object(_) as request) {
      return Some(request)
    }
  }

  None
}

///|
fn list_directory_names(
  path : String,
) -> Array[String] raise @failure.TaskFailed {
  let names = @store.list_directory_if_exists(path) catch {
    failed => @failure.fail(failed.user_message())
  }

  names.unwrap_or([])
}
