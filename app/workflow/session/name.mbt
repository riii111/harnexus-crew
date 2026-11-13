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
  let worker = @request.caller_id(ctx.env)
  // Linked first and for any chat, so a worker the owner started by hand is still watched.
  // A worker naming its PR takes it over, as the latest worker on a PR is the one doing it; pr-wake keeps the start of a link the same chat renews.
  let linked = (ctx.pr_wake)(["link", args.pr, "--take-over"])
  let watched = match linked.get("watched") {
    Some(String(watched)) => Some(watched)
    _ => None
  }
  let request = if ctx.host.renames_threads {
    launch_of_thread(ctx.env, worker)
  } else {
    None
  }
  // Only a launched worker has a title to extend; another chat keeps its own.
  // The number goes last so the title still reads as the task, while a search for the PR finds the worker.
  let title = match request {
    Some(request) => Some("\{thread_title("Impl", request)} PR#\{number}")
    None => None
  }
  let answer = match title {
    Some(title) =>
      Some(
        (ctx.ports.call)(worker, "name_thread", { "name": Json::string(title) }),
      )
    None => None
  }
  let renamed = match answer {
    Some(answer) => answer.outcome == "done"
    None => true
  }
  // Fails even after a rename, so a PR the watch cannot see is never taken as watched.
  guard watched is Some(watched) else {
    let renamed_as = match title {
      Some(title) if renamed => " (the thread is named \{title})"
      _ => ""
    }
    @failure.fail(
      "\{args.pr} is not watched\{renamed_as}: \{@watch.NOT_LINKABLE}",
    )
  }
  let shown : Map[String, Json] = {
    "threadId": Json::string(worker),
    "title": match title {
      Some(title) if renamed => Json::string(title)
      _ => Json::null()
    },
    "watched": Json::string(watched),
  }
  // A rename the app did not apply leaves the PR watched, which the result says rather than failing.
  if !renamed {
    let applied = match answer {
      Some(answer) => answer.to_json().stringify()
      None => "null"
    }
    shown["renameError"] = Json::string(
      "name_thread was not applied: \{applied}",
    )
  }
  // pr-wake warns about a linked chat nothing can send to, which the link alone would show as watched.
  if linked.get("warning") is Some(String(warning)) {
    shown["warning"] = Json::string(warning)
  }
  Json::object(shown)
}

///|
fn launch_of_thread(
  env : @environment.Env,
  thread : String,
) -> Json? raise @failure.TaskFailed {
  // A worker is never told the request's path, so its launch is found from the thread it runs in.
  let root = @path.join([env.state_root(), "launch"])
  let keys = names_in(root)
  keys.sort_by(@text.compare_utf16)
  for key in keys {
    let directory = @path.join([root, key])
    if !@store.is_directory(directory) {
      continue
    }
    // Another task's unreadable state is skipped, so it cannot stop every worker from finding its own.
    let state = @store.load(@path.join([directory, "state.json"])) catch {
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
fn names_in(path : String) -> Array[String] raise @failure.TaskFailed {
  let names = @store.list_directory_if_exists(path) catch {
    failed => @failure.fail(failed.user_message())
  }
  names.unwrap_or([])
}
