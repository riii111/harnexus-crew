///|
/// Runs one invocation of the CLI and returns what it prints and the code it ends with.
/// `argv` is the arguments after the program's name.
/// `read_env` is called only once the arguments are accepted, so help and usage errors need no environment.
pub async fn run(
  argv : ArrayView[String],
  read_env : () -> @environment.Env raise,
) -> @run.CommandRun {
  dispatch(argv, read_env) catch {
    error => crash_run(error)
  }
}

///|
async fn dispatch(
  argv : ArrayView[String],
  read_env : () -> @environment.Env raise,
) -> @run.CommandRun {
  let command = match argv {
    [first, ..] => first
    [] => ""
  }
  // adapter is outside the task commands' usage, as it is in the TypeScript build.
  if !@args.command_names().contains(command) && command != "adapter" {
    let help = command == "-h" || command == "--help"
    let usage = usage_of(@args.command_names(), @environment.NAME)
    return if help {
      help_run(usage)
    } else {
      usage_error_run(
        usage,
        @environment.NAME,
        "expected a subcommand: \{@args.command_names().join(", ")}",
      )
    }
  }
  if command == "adapter" {
    return adapter_run(argv[1:], read_env)
  }
  let usage = usage_of([command], @environment.NAME)
  match parse(command, argv[1:]) {
    Err(message) => usage_error_run(usage, @environment.NAME, message)
    Ok(Help) => help_run(usage)
    Ok(Run(parsed)) => execute(parsed, read_env)
  }
}

///|
fn parse(
  command : String,
  rest : ArrayView[String],
) -> Result[@args.Parsed, String] {
  Ok(@args.parse_command(command, rest)) catch {
    @args.UsageError(message) => Err(message)
  }
}

///|
/// A failure the user is meant to read ends the run with 1; anything else is a crash.
async fn execute(
  command : @args.Command,
  read_env : () -> @environment.Env raise,
) -> @run.CommandRun {
  let env = read_env()
  try {
    if !(command is Environment) && !env.home_known() {
      raise HomeNotFound
    }
    let result = run_command(command, env)
    { code: 0, stdout: @jsonio.stringify(result) + "\n", stderr: "", }
  } catch {
    @failure.TaskFailed(message) => failure_run(message)
    other => raise other
  }
}

///|
fn failure_run(message : String) -> @run.CommandRun {
  { code: 1, stdout: "", stderr: "\{@environment.NAME}: \{message}\n", }
}
