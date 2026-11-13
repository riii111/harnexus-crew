///|
const PR_WAKE_VARIABLE : String = "HARNEXUS_CREW_PR_WAKE"

///|
const ENGINE : String = "pr-wake-engine"

///|
/// A dry run reads every configured PR from GitHub, so it is given as long as a person waits for it.
const DRY_RUN_TIMEOUT_MS : Int32 = 600000

///|
const CALL_TIMEOUT_MS : Int32 = 60000

///|
/// Runs one pr-wake watch subcommand and returns the one JSON object it prints.
pub async fn call(
  env : @environment.Env,
  args : Array[String],
) -> Map[String, Json] raise @failure.TaskFailed {
  call_within(env, args, timeout_of(args))
}

///|
fn timeout_of(args : Array[String]) -> Int32 {
  match args.get(0) {
    Some("dry-run") => DRY_RUN_TIMEOUT_MS
    _ => CALL_TIMEOUT_MS
  }
}

///|
async fn call_within(
  env : @environment.Env,
  args : Array[String],
  timeout_ms : Int32,
) -> Map[String, Json] raise @failure.TaskFailed {
  let command = command_of(env)
  let argv = ["watch"]
  argv.append(args)
  let ran = @process.run_command(command, argv, env.to_map(), timeout_ms~) catch {
    @boundary.CommandFailed(message~, ..) =>
      @failure.fail(
        "\{message}; install pr-wake, or set \{PR_WAKE_VARIABLE} to its absolute path",
      )
  }
  let said = @text.js_trim(ran.stderr)
  if ran.status != 0 {
    let detail = if said == "" { "" } else { ": \{said}" }
    @failure.fail(
      "pr-wake watch \{args.join(" ")} failed with exit \{ran.status}\{detail}",
    )
  }
  let parsed = @jsonio.parse(@text.js_trim(ran.stdout)) catch {
    _ => Json::null()
  }
  match parsed {
    Object(printed) => printed
    _ => @failure.fail("pr-wake watch \{args.join(" ")} printed no JSON object")
  }
}

///|
/// The pr-wake command, found on PATH unless an absolute path is set, so the watch is owned and updated by pr-wake alone.
fn command_of(env : @environment.Env) -> String raise @failure.TaskFailed {
  match env.get_nonempty(PR_WAKE_VARIABLE) {
    None => "pr-wake"
    Some(set) =>
      if @path.is_absolute(set) {
        set
      } else {
        @failure.fail("\{PR_WAKE_VARIABLE} must be an absolute path")
      }
  }
}

///|
/// The engine pr-wake installs beside itself, which its LaunchAgent runs; the long-running watch is handed to it.
fn engine_of(
  env : @environment.Env,
  which~ : (String) -> String?,
) -> String raise @failure.TaskFailed {
  let command = command_of(env)
  let found = if @path.is_absolute(command) {
    Some(command)
  } else {
    which(command)
  }
  guard found is Some(found) else {
    @failure.fail(
      "pr-wake is not on PATH; install pr-wake, or set \{PR_WAKE_VARIABLE} to its absolute path",
    )
  }
  @path.join([@path.dirname(@store.real_path_or_self(found)), ENGINE])
}

///|
pub async fn hand_over(
  env : @environment.Env,
  which~ : (String) -> String?,
) -> Json raise @failure.TaskFailed {
  let engine = engine_of(env, which~)
  let exited = @process.run_inherited(engine, ["watch"], env.to_map()) catch {
    @boundary.CommandFailed(message~, ..) => @failure.fail(message)
  }
  if exited != 0 {
    @failure.fail("\{engine} watch exited with \{exited}")
  }
  { "watch": "stopped" }
}
