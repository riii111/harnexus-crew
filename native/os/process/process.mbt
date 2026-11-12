///|
/// Runs a command with `input` on its stdin and returns once it has exited and its output has been read to the end.
/// The command leads its own process group, so a child it started does not outlive it.
/// At the deadline, or when the output passes 16 MiB, the group gets SIGTERM and then SIGKILL after `kill_grace_ms`.
/// The result then says why the run ended, and anything but `Exit` means the command's own result is unknown.
/// A command still alive a second grace after SIGKILL raises with `started` true.
pub async fn run_process(
  file : String,
  args : ArrayView[String],
  input : String,
  cwd~ : String,
  env~ : Map[String, String],
  timeout_ms~ : Int32,
  kill_grace_ms~ : Int32,
) -> @boundary.ProcessRun raise @boundary.ProcessRunFailed {
  let failed = (started : Bool, reason : String) => {
    @boundary.ProcessRunFailed(
      started~,
      message="\{file} did not finish: \{reason}",
    )
  }
  let child = spawn(file, args, env, cwd, piped=true, new_session=true) catch {
    err => raise failed(false, spawn_reason(file, err))
  }
  defer {
    child.stop_and_reap()
    child.release_pipes()
  }
  let capture = Capture::new()
  let ended = Ref(@boundary.ProcessEnd::Exit)
  let exited = Ref(false)
  let exit = Ref(Exit::Code(0))
  @async.with_task_group(group => {
    let stop = (reason : @boundary.ProcessEnd) => {
      if ended.val is Exit && !exited.val {
        ended.val = reason
        group.spawn_bg(no_wait=true, () => {
          ignore(child.signal(SIGTERM, group=true))
          @async.sleep(kill_grace_ms)
          ignore(child.signal(SIGKILL, group=true))
          @async.sleep(kill_grace_ms)
          raise StillAlive
        })
      }
    }
    group.spawn_bg(no_wait=true, () => {
      @async.sleep(timeout_ms)
      stop(Timeout)
    })
    group.spawn_bg(no_wait=true, () => feed_input(child.stdin, input))
    let reading_out = group.spawn(() => {
      capture.drain(child.stdout, capture.stdout, () => stop(OutputLimit))
    })
    let reading_err = group.spawn(() => {
      capture.drain(child.stderr, capture.stderr, () => stop(OutputLimit))
    })
    let waiting = group.spawn(() => child.wait_exit())
    reading_out.wait()
    reading_err.wait()
    exit.val = waiting.wait()
    exited.val = true
  }) catch {
    StillAlive =>
      raise failed(true, "pid \{child.pid} did not exit after SIGKILL")
    err => raise failed(true, err.to_string())
  }
  // Anything the command left in its group goes with it.
  ignore(child.signal(SIGKILL, group=true))
  {
    status: match exit.val {
      Code(code) => code
      Signaled(_) => 1
    },
    stdout: @utf8.decode_lossy(capture.stdout.to_bytes()),
    stderr: @utf8.decode_lossy(capture.stderr.to_bytes()),
    ended: ended.val,
  }
}

///|
/// The command was told to stop twice and is still running.
priv suberror StillAlive

///|
/// The input goes through stdin so it never shows in the process list.
/// A command that exits without reading closes its end, which does not fail the run.
async fn feed_input(slot : Fd, input : String) -> Unit {
  let stream = slot.stream()
  defer stream.close()
  if input != "" {
    stream.write(@utf8.encode(@jsonio.lossy_text(input))) catch {
      _ => ()
    }
  }
}
