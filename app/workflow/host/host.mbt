///|
/// The thinking a worker and a reviewer get when none is asked for.
pub struct DefaultThinking {
  worker : String
  reviewer : String
}

///|
/// What differs between the apps a worker and its reviewer run in; everything else a task does is the same in both.
pub struct Host {
  /// The variable naming the thread a command runs in.
  thread_variable : String
  /// Sends an App operation as the caller's thread: caller, tool, arguments.
  call : async (String, String, Map[String, Json]) -> @bridge.CallAnswer noraise
  /// The project a reviewer is started in, as the app's create_thread target names it.
  review_project : async (String) -> String raise @failure.TaskFailed
  /// The folder whose <id>/<name> folders are worker worktrees.
  worktrees : String
  /// None when the app cannot be told a thinking.
  thinking : DefaultThinking?
  /// Which reply template a reviewer follows to hand its result to the worker, by the worker's AI.
  reply_to : (String) -> String
  /// Whether name --pr can rename the worker's thread to show its PR.
  renames_threads : Bool
}

///|
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
    call: (caller, tool, args) => @bridge.call_app(env, caller, tool, args),
    review_project: caller => find_codex_review_project(env, caller),
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
    call: (_, tool, args) => @bridge.call_t3(env, tool, args, which~),
    // The t3 CLI takes a folder for its project, and says so when no project holds it.
    review_project: _ => resolve_review_home(env),
    // T3 Code keeps a worktree at <repository name>/<branch> under its own folder.
    worktrees: env.worktrees(app),
    thinking: None,
    // A reviewer in T3 Code answers through T3 Code's own thread tools, whichever AI the worker is.
    reply_to: _ => "T3",
    // The t3 CLI cannot rename a thread.
    renames_threads: false,
  }
}

///|
async fn find_codex_review_project(
  env : @environment.Env,
  caller : String,
) -> String raise @failure.TaskFailed {
  let home = resolve_review_home(env)
  let answer = @bridge.call_app(env, caller, "list_projects", {})
  if answer.outcome != "done" {
    @failure.fail("list_projects failed: \{answer.to_json().stringify()}")
  }

  if @bridge.find_project_id(answer.fields.get("result"), home)
    is Some(project_id) {
    return project_id
  }

  @failure.fail(
    "add \{home} to the Codex app as a project, so reviewers run there instead of in a worktree of their own",
  )
}

///|
fn resolve_review_home(env : @environment.Env) -> String {
  // To avoid creating a worktree for each review, use the existing empty project.
  @store.resolve_real_path_or_self(@path.join([env.home(), "review-home"]))
}
