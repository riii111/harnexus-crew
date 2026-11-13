///|
/// Links the worker's PR to its thread, so the PR's activity wakes the worker, and shows the PR in the thread's title.
pub async fn name(
  args : @args.NameArgs,
  env : @environment.Env,
  which~ : (String) -> String?,
) -> Json raise @failure.TaskFailed {
  name_in(Context::of_env(env, which~), args)
}

///|
async fn name_in(
  ctx : Context,
  args : @args.NameArgs,
) -> Json raise @failure.TaskFailed {
  @environment.refuse_in_cloud(ctx.env, "name")
  let number = match pr_number(args.pr) {
    Some(number) => number
    None => @failure.fail("--pr must be a pull request URL or number")
  }
  let worker = @request.caller_id(ctx.env)
  // Linked first and for any chat, so a worker the owner started by hand is still watched.
  // A worker naming its PR takes it over, as the latest worker on a PR is the one doing it; pr-wake keeps the start of a link the same chat renews.
  let linked = if @prwake.is_github_pr(args.pr) {
    Some((ctx.pr_wake)(["link", args.pr, "--take-over"]))
  } else {
    None
  }
  let watched = match linked {
    Some(members) =>
      match members.get("watched") {
        Some(String(watched)) => Some(watched)
        _ => None
      }
    None => None
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
      "\{args.pr} is not watched\{renamed_as}: \{@prwake.NOT_LINKABLE}",
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
  if linked is Some(members) && members.get("warning") is Some(String(warning)) {
    shown["warning"] = Json::string(warning)
  }
  Json::object(shown)
}

///|
/// The launch request of the worker that runs in the thread.
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

///|
/// The number of a pull request given as `123`, `#123` or the URL of its page, which may carry a tab, query or fragment after the number, as when copied from the browser.
fn pr_number(pr : String) -> String? {
  let bare = if pr.has_prefix("#") { pr[1:].to_owned() } else { pr }
  if is_pr_digits(bare) {
    return Some(bare)
  }
  if !pr.has_prefix("https://") || @text.has_js_whitespace(pr) {
    return None
  }
  // The last "/pull/" that is followed by a number and the end of the URL or one of /?# decides, as a pattern with a greedy host and path would take it.
  let marker = "/pull/"
  let mut at = pr.length() - marker.length()
  while at >= "https://".length() + 1 {
    if units_at(pr, at, marker) {
      let digits_from = at + marker.length()
      let mut end = digits_from
      while end < pr.length() && is_ascii_digit(pr[end]) {
        end += 1
      }
      let digits = pr[digits_from:end].to_owned()
      if is_pr_digits(digits) &&
        (
          end == pr.length() ||
          is_unit(pr[end], '/') ||
          is_unit(pr[end], '?') ||
          is_unit(pr[end], '#')
        ) {
        return Some(digits)
      }
    }
    at -= 1
  }
  None
}

///|
fn is_pr_digits(text : String) -> Bool {
  text.length() > 0 &&
  !is_unit(text[0], '0') &&
  is_ascii_digit(text[0]) &&
  (for i in 1..<text.length() {
    if !is_ascii_digit(text[i]) {
      break false
    }
  } nobreak {
    true
  })
}

///|
fn is_ascii_digit(unit : UInt16) -> Bool {
  unit.to_int() >= 0x30 && unit.to_int() <= 0x39
}

///|
fn is_unit(unit : UInt16, char : Char) -> Bool {
  unit.to_int() == char.to_int()
}

///|
fn units_at(text : String, at : Int32, sub : String) -> Bool {
  if at < 0 || at + sub.length() > text.length() {
    return false
  }
  for i in 0..<sub.length() {
    if text[at + i] != sub[i] {
      return false
    }
  }
  true
}
