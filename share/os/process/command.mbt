///|
const COMMAND_KILL_GRACE_MS : Int32 = 1000

///|
/// Runs a short command and returns what it printed.
/// raises       : When the command cannot start, is stopped by the timeout, prints more than 16 MiB in all, dies from a signal, or survives SIGKILL.
/// stdin        : Closed at once, so a command that reads it sees the end of input.
/// process group: The command leads its own process group.
/// stop         : At the timeout or the output limit the group gets SIGTERM, then SIGKILL after one second.
pub async fn run_command(
  file : String,
  args : ArrayView[String],
  env : Map[String, String],
  timeout_ms~ : Int32 = 10000,
) -> @boundary.CommandOutput raise @boundary.CommandFailed {
  let failed = (message : String, code : String?) => {
    @boundary.CommandFailed(command=file, message~, code~)
  }

  let child = spawn(file, args, env, "", piped=true, new_session=true) catch {
    err => raise failed("cannot run \{file}", Some(err.code()))
  }
  defer {
    child.stop_and_reap()
    child.release_pipes()
  }

  let run = supervise(
    child,
    "",
    timeout_ms~,
    kill_grace_ms=COMMAND_KILL_GRACE_MS,
  ) catch {
    StillAlive =>
      raise failed(
        "\{file} did not finish: pid \{child.pid} did not exit after SIGKILL",
        None,
      )
    _ => raise failed("cannot run \{file}", None)
  }

  match (run.ended, run.exit) {
    (Timeout, _) =>
      raise failed("\{file} was stopped after \{timeout_ms} ms", None)
    (OutputLimit, _) =>
      raise failed(
        "cannot run \{file}",
        Some("ERR_CHILD_PROCESS_STDIO_MAXBUFFER"),
      )
    (Exit, Signaled(_)) => raise failed("cannot run \{file}", None)
    (Exit, Code(status)) =>
      {
        status,
        stdout: @utf8.decode_lossy(run.stdout),
        stderr: @utf8.decode_lossy(run.stderr),
      }
  }
}

///|
/// Runs a long-lived command on this process's own stdin, stdout and stderr and returns its exit status.
/// A command killed by a signal answers 128 plus the signal number.
/// Cancelling the wait leaves the command running.
pub async fn run_inherited(
  file : String,
  args : ArrayView[String],
  env : Map[String, String],
) -> Int32 raise @boundary.CommandFailed {
  let child = spawn(file, args, env, "", piped=false, new_session=false) catch {
    err =>
      raise @boundary.CommandFailed(
        command=file,
        message="cannot run \{file}",
        code=Some(err.code()),
      )
  }

  match child.wait_exit(patience_ms=50) {
    Code(status) => status
    Signaled(sig) => 128 + sig
  }
}
