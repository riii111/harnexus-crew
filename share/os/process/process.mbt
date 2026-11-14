///|
/// The command was told to stop twice and is still running.
priv suberror StillAlive

///|
/// Runs a command in its own process group, so a child it started does not outlive it.
/// Returns after the command exits and its output is read to the end.
/// stop         : At the deadline or above 16 MiB of output, the group gets SIGTERM, then SIGKILL after `kill_grace_ms`.
/// still running: Raises with `started` true if the command is alive a second grace after SIGKILL.
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
    err =>
      raise @boundary.ProcessRunFailed(
        started=false,
        message="cannot run \{file} (\{err.code()})",
      )
  }
  defer {
    child.stop_and_reap()
    child.release_pipes()
  }
  let run = supervise(child, input, timeout_ms~, kill_grace_ms~) catch {
    StillAlive =>
      raise failed(true, "pid \{child.pid} did not exit after SIGKILL")
    err => raise failed(true, err.to_string())
  }
  {
    status: match run.exit {
      Code(code) => code
      Signaled(_) => 1
    },
    stdout: @utf8.decode_lossy(run.stdout),
    stderr: @utf8.decode_lossy(run.stderr),
    ended: run.ended,
  }
}

///|
priv struct Supervised {
  exit : Exit
  ended : @boundary.ProcessEnd
  // To preserve UTF-8 characters split across chunks, the output stays bytes until all of it is collected.
  stdout : Bytes
  stderr : Bytes
}

///|
async fn supervise(
  child : Child,
  input : String,
  timeout_ms~ : Int32,
  kill_grace_ms~ : Int32,
) -> Supervised {
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
    // To keep the input out of the process list, it goes through stdin.
    group.spawn_bg(no_wait=true, () => feed_input(child.stdin, input))
    // One count over both streams: the limit bounds what a run keeps in memory.
    let size = Ref(0)
    let reading_out = group.spawn(() => {
      drain(child.stdout, capture.stdout, size, () => stop(OutputLimit))
    })
    let reading_err = group.spawn(() => {
      drain(child.stderr, capture.stderr, size, () => stop(OutputLimit))
    })
    let waiting = group.spawn(() => child.wait_exit())
    reading_out.wait()
    reading_err.wait()
    exit.val = waiting.wait()
    exited.val = true
  })
  child.sweep_group()
  {
    exit: exit.val,
    ended: ended.val,
    stdout: capture.stdout.to_bytes(),
    stderr: capture.stderr.to_bytes(),
  }
}

///|
async fn feed_input(slot : Fd, input : String) -> Unit {
  let stream = slot.into_stream()
  defer stream.close()
  if input != "" {
    // A command that exits without reading closes its end, so a failed write is ignored instead of failing the run.
    stream.write(@utf8.encode(input)) catch {
      _ => ()
    }
  }
}
