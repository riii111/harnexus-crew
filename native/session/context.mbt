///|
/// What one run of a session command works with.
/// A test replaces the parts that reach the app, Git, the templates and pr-wake.
priv struct Context {
  env : @environment.Env
  host : @app.Host
  ports : Ports
  /// The project a reviewer is started in.
  review_project : async (String) -> String raise @failure.TaskFailed
  probe : @request.FileProbe
  git : @request.Git
  prompt : (@prompt.TemplateKind, Map[String, String]) -> String raise @failure.TaskFailed
  pr_wake : async (Array[String]) -> Map[String, Json] raise @failure.TaskFailed
}

///|
/// The context of the real machine: the app the thread runs in, the repository's Git, the configured templates and pr-wake.
/// `which` finds a program on PATH.
fn Context::of_env(
  env : @environment.Env,
  which~ : (String) -> String?,
) -> Context {
  let host = @app.host_of(env, which~)
  {
    env,
    host,
    ports: ports_of(host),
    review_project: host.review_project,
    probe: @request.FileProbe::of_machine(),
    git: @request.Git::of_env(env),
    prompt: (kind, fields) => @prompt.task_prompt(env, kind, fields),
    pr_wake: args => @prwake.call(env, args),
  }
}

///|
/// Reads a request file as JSON.
fn read_json(path : String) -> Json raise @failure.TaskFailed {
  let text = @store.read_regular_text(path) catch {
    failed => @failure.fail(failed.user_message())
  }
  @jsonio.parse(text) catch {
    _ => @failure.fail("\{path} is not valid JSON")
  }
}

///|
/// A model or thinking the user named; an empty one counts as not named.
fn named(value : String?) -> String? {
  match value {
    Some("") | None => None
    other => other
  }
}
