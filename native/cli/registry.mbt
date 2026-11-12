///|
/// Each command has one arm here, which a command's task replaces with a call into its own package.
async fn run_command(command : @args.Command, env : @environment.Env) -> Json {
  match command {
    Environment => environment_command(env)
    State({ request: None, }) => state_command(env)
    State({ request: Some(_), }) => not_migrated("state --request")
    Launch(_) => not_migrated("launch")
    Review(_) => not_migrated("review")
    Resolve(_) => not_migrated("resolve")
    Name(_) => not_migrated("name")
    Watch(args) => @prwake.watch(args, env, which=@which.in_env(env))
    Check => @prompt.check_templates(env)
    Cloud(_) => not_migrated("cloud")
  }
}

///|
/// A command no task has moved to the native build fails here, and never falls back to the TypeScript build.
fn[T] not_migrated(name : String) -> T raise @failure.TaskFailed {
  @failure.fail(not_migrated_message(name))
}

///|
fn not_migrated_message(name : String) -> String {
  "\{name} is not available in this native build yet"
}

///|
/// `adapter` is apart from the task commands: it can serve a bridge for as long as the bridge keeps it, and has its own usage.
async fn adapter_run(
  argv : ArrayView[String],
  read_env : () -> @environment.Env raise,
) -> @run.CommandRun {
  @adapter.run(argv, () => {
    let env = read_env()
    if !env.home_known() {
      raise HomeNotFound
    }
    env
  })
}
