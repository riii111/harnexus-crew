///|
async fn run_command(command : @args.Command, env : @environment.Env) -> Json {
  match command {
    Environment => @status.environment_command(env)
    State({ request: None, }) => @status.state_command(env)
    State({ request: Some(request), }) =>
      @session.show_request_state(request, env, which=@which.in_env(env))
    Launch(args) => @session.launch(args, env, which=@which.in_env(env))
    Review(args) =>
      @session.review(args, env, which=@which.in_env(env), cloud=args => {
        @cloud.review(args, env)
      })
    Resolve(args) => @session.resolve(args, env, which=@which.in_env(env))
    Name(args) => @session.name(args, env, which=@which.in_env(env))
    Watch(args) => @watch.watch(args, env, which=@which.in_env(env))
    Check => @prompt.check_templates(env)
    Cloud(args) => @cloud.open_chat(args, env)
  }
}

///|
async fn adapter_run(
  argv : ArrayView[String],
  read_env : () -> @environment.Env raise,
) -> @run.CommandRun {
  @adapter.run(argv, () => {
    let env = read_env()
    @workflow.require_home(env)
    env
  })
}
