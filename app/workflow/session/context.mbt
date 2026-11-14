///|
priv struct Context {
  env : @environment.Env
  host : @host.Host
  ports : Ports
  /// The project a reviewer is started in.
  review_project : async (String) -> String raise @failure.TaskFailed
  probe : @request.FileProbe
  git : @git.Git
  prompt : (@prompt.TemplateKind, Map[String, String]) -> String raise @failure.TaskFailed
  pr_wake : async (Array[String]) -> Map[String, Json] raise @failure.TaskFailed
}

///|
fn Context::of_env(
  env : @environment.Env,
  which~ : (String) -> String?,
) -> Context {
  let host = @host.host_of(env, which~)
  {
    env,
    host,
    ports: ports_of(host),
    review_project: host.review_project,
    probe: @request.FileProbe::of_machine(),
    git: @git.Git::of_env(env),
    prompt: (kind, fields) => @prompt.render_task_prompt(env, kind, fields),
    pr_wake: args => @prwake.call(env, args),
  }
}

///|
fn ports_of(host : @host.Host) -> Ports {
  {
    call: host.call,
    save: (path, data, exclusive) => @store.save_json(path, data, exclusive~),
  }
}
