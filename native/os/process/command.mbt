///|
/// Runs a short command and returns what it printed.
/// Any exit status is a result; the caller decides what a failure means.
/// A command that cannot start, is stopped by the timeout, prints more than 16 MiB, or dies from a signal raises.
/// Its stdin is an open pipe that is never written, and a command that outlives the timeout gets SIGTERM only.
pub async fn run_command(
  file : String,
  args : ArrayView[String],
  env : Map[String, String],
  timeout_ms~ : Int32 = 10000,
) -> @boundary.CommandOutput raise @boundary.CommandFailed {
  let failed = (message : String) => {
    @boundary.CommandFailed(command=file, message~)
  }
  let child = spawn(file, args, env, "", piped=true, new_session=false) catch {
    _ => raise failed("cannot run \{file}")
  }
  defer {
    child.stop_and_reap()
    child.release_pipes()
  }
  let capture = Capture::new()
  let stopped = Ref(false)
  let overflowed = Ref(false)
  let exit = Ref(Exit::Code(0))
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      @async.sleep(timeout_ms)
      if child.signal(SIGTERM, group=false) {
        stopped.val = true
      }
    })
    let on_limit = () => {
      if !overflowed.val {
        overflowed.val = true
        ignore(child.signal(SIGTERM, group=false))
      }
    }
    // execFile applies its limit to each stream on its own.
    let reading_out = group.spawn(() => {
      drain(child.stdout, capture.stdout, Ref(0), on_limit)
    })
    let reading_err = group.spawn(() => {
      drain(child.stderr, capture.stderr, Ref(0), on_limit)
    })
    let waiting = group.spawn(() => child.wait_exit())
    reading_out.wait()
    reading_err.wait()
    exit.val = waiting.wait()
  }) catch {
    _ => raise failed("cannot run \{file}")
  }
  if stopped.val {
    raise failed("\{file} was stopped after \{timeout_ms} ms")
  }
  match exit.val {
    Code(status) if !overflowed.val =>
      {
        status,
        stdout: @utf8.decode_lossy(capture.stdout.to_bytes()),
        stderr: @utf8.decode_lossy(capture.stderr.to_bytes()),
      }
    _ => raise failed("cannot run \{file}")
  }
}

///|
/// Runs a long-lived command on this process's own stdin, stdout and stderr and returns its exit status, for a program that hands its work to another.
/// A command killed by a signal answers 128 plus the signal number.
/// Cancelling the wait leaves the command running.
pub async fn run_inherited(
  file : String,
  args : ArrayView[String],
  env : Map[String, String],
) -> Int32 raise @boundary.CommandFailed {
  let child = spawn(file, args, env, "", piped=false, new_session=false) catch {
    _ =>
      raise @boundary.CommandFailed(command=file, message="cannot run \{file}")
  }
  match child.wait_exit(patience_ms=50) {
    Code(status) => status
    Signaled(sig) => 128 + sig
  }
}

///|
/// What Bun says when a command cannot be started, which reaches the user inside a process failure.
fn spawn_reason(file : String, err : SpawnFailed) -> String {
  match err {
    InvalidArgument => "The argument must be a string without null bytes"
    SpawnFailed(errno~) =>
      if @unix.errno_name(errno) == "ENOENT" && !file.contains("/") {
        "Executable not found in $PATH: \"\{file}\""
      } else {
        "\{@unix.errno_message(errno)}, posix_spawn '\{file}'"
      }
  }
}
