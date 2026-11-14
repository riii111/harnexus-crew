///|
pub(all) struct GitRunner {
  /// Runs a command and returns what it printed; a command that ran counts as a result whatever its exit status.
  run : async (Array[String], Map[String, String]) -> @boundary.CommandOutput raise @boundary.CommandFailed
}

///|
pub struct Git {
  priv runner : GitRunner
  priv env : @environment.Env
}

///|
pub fn Git::new(runner : GitRunner, env : @environment.Env) -> Git {
  { runner, env, }
}

///|
pub fn Git::of_env(env : @environment.Env) -> Git {
  Git::new(
    { run: (argv, vars) => @process.run_command(argv[0], argv[1:], vars), },
    env,
  )
}

///|
/// Runs `git -C checkout args` and returns its trimmed output; a failing status becomes the failure.
pub async fn Git::run(
  self : Git,
  checkout : String,
  args : Array[String],
) -> String raise @failure.TaskFailed {
  let argv = ["git"]
  argv.append(git_safety)
  argv.push("-C")
  argv.push(checkout)
  argv.append(args)
  let env = self.env.to_map()
  env["GIT_NO_LAZY_FETCH"] = "1"
  let output = (self.runner.run)(argv, env) catch {
    @boundary.CommandFailed(message~, code~, ..) =>
      @failure.fail(
        match code {
          Some(code) => "\{message} (\{code})"
          None => message
        },
      )
  }

  if output.status != 0 {
    @failure.fail(
      "\{@text.js_trim(output.stderr)}; \{@environment.NAME} never fetches, so fetch any missing commit in the worktree",
    )
  }

  @text.js_trim(output.stdout)
}

///|
/// The command runs unsandboxed, so repository config must never start helpers or transports.
let git_safety : Array[String] = [
  "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "protocol.allow=never",
]
