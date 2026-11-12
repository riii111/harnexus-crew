///|
/// The thinking a worker and a reviewer get when none is asked for.
pub(all) struct DefaultThinking {
  worker : String
  reviewer : String
}

///|
/// What differs between the apps a worker and its reviewer run in; everything else a task does is the same in both.
pub struct Host {
  // The variable naming the thread a command runs in.
  thread_variable : String
  // Sends an App operation as the caller's thread: caller, tool, arguments.
  call : async (String, String, Map[String, Json]) -> @call.CallAnswer noraise
  // The project a reviewer is started in, as the app's create_thread target names it.
  review_project : async (String) -> String raise @failure.TaskFailed
  // The folder whose <id>/<name> folders are worker worktrees.
  worktrees : String
  // None when the app cannot be told a thinking.
  thinking : DefaultThinking?
  // Which reply template a reviewer follows to hand its result to the worker, by the worker's AI.
  reply_to : (String) -> String
  // Whether name --pr can rename the worker's thread to show its PR.
  renames_threads : Bool
}

///|
/// `which` finds a program on PATH.
pub fn host_of(env : @environment.Env, which~ : (String) -> String?) -> Host {
  let app = @environment.app_of(env)
  match app {
    T3 => t3_host(env, app, which)
    Codex => codex_host(env, app)
  }
}

///|
fn codex_host(env : @environment.Env, app : @environment.App) -> Host {
  {
    thread_variable: @environment.thread_variable(app),
    call: (caller, tool, args) => call_app(env, caller, tool, args),
    review_project: caller => codex_review_project(env, caller),
    worktrees: env.worktrees(app),
    thinking: Some({ worker: "high", reviewer: "medium", }),
    reply_to: worker_ai => worker_ai,
    renames_threads: true,
  }
}

///|
fn t3_host(
  env : @environment.Env,
  app : @environment.App,
  which : (String) -> String?,
) -> Host {
  {
    thread_variable: @environment.thread_variable(app),
    call: (_, tool, args) => call_t3({ env, which, }, tool, args),
    // The t3 CLI takes a folder for its project, and says so when no project holds it.
    review_project: _ => review_home(env),
    // T3 Code keeps a worktree at <repository name>/<branch> under its own folder.
    worktrees: env.worktrees(app),
    thinking: None,
    // A reviewer in T3 Code answers through T3 Code's own thread tools, whichever AI the worker is.
    reply_to: _ => "T3",
    // The t3 CLI cannot rename a thread; a worker renames its own with T3 Code's t3_thread_update.
    renames_threads: false,
  }
}

///|
async fn codex_review_project(
  env : @environment.Env,
  caller : String,
) -> String raise @failure.TaskFailed {
  let home = review_home(env)
  let answer = call_app(env, caller, "list_projects", {})
  if answer.outcome != "done" {
    @failure.fail(
      "list_projects failed: \{@jsonio.stringify(answer.to_json())}",
    )
  }
  for project in projects_in(answer.fields.get("result")) {
    guard project is Object(members) else { continue }
    guard members.get("path") is Some(String(path)) &&
      members.get("projectId") is Some(String(project_id)) else {
      continue
    }
    if @store.real_path_or_self(path) == home {
      return project_id
    }
  }
  @failure.fail(
    "add \{home} to the Codex app as a project, so reviewers run there instead of in a worktree of their own",
  )
}

///|
/// A reviewer reads the worker's checkout by its path, so it runs in an empty project rather than a worktree of its own that counts toward the app's worktree limit.
fn review_home(env : @environment.Env) -> String {
  @store.real_path_or_self(@path.join([env.home(), "review-home"]))
}
