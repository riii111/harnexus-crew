///|
priv struct Parts {
  store : ReviewStore
  observations : Observations
  locks : String
}

///|
fn build_parts(env : @environment.Env) -> Parts raise @failure.TaskFailed {
  let root = observation_root(env)
  let locks = @path.join([root, "locks"])
  {
    store: ReviewStore::new(reviews_directory(env), locks),
    observations: Observations::new(root),
    locks,
  }
}

///|
/// Writes whole texts one at a time, so lines from concurrent tasks never mix.
/// A stream the reader has closed loses its text; the adapter has nowhere else to report it.
async fn emit(
  stream : @stdio.Output,
  gate : @async.Mutex,
  text : String,
) -> Unit noraise {
  gate.acquire()
  defer gate.release()
  stream.write(@utf8.encode(@jsonio.lossy_text(text))) catch {
    _ => ()
  }
}

///|
fn log_text(entry : Array[(String, Json)]) -> String {
  let line = [("time", Json::string(@store.now_iso())), ..entry]
  @jsonio.stringify(object(line)) + "\n"
}

///|
/// The lines one chunk read up to a `\n` holds, split where Node's readline splits: `\r\n`, `\n` and a lone `\r`.
fn split_lines(chunk : String) -> Array[String] {
  let text = if chunk.has_suffix("\r") {
    chunk[:chunk.length() - 1].to_owned()
  } else {
    chunk
  }
  text.split("\r").map(line => line.to_owned()).collect()
}

///|
async fn pump(adapter : Adapter, handlers : @async.TaskGroup) -> Unit noraise {
  while true {
    let chunk = match
      (Ok(@stdio.stdin.read_until(b"\n")) catch { e => Err(e) }) {
      Ok(Some(bytes)) => @utf8.decode_lossy(bytes)
      _ => break
    }
    for line in split_lines(chunk) {
      match adapter.accept(line) {
        Handled => ()
        Later(work) => handlers.spawn_bg(() => work())
      }
    }
  }
}

///|
/// Serves one bridge connection on stdin and stdout until the bridge closes it; every line it cannot use is logged to stderr, which the bridge discards.
async fn serve(env : @environment.Env, adapter_id : String) -> @run.CommandRun {
  let parts = build_parts(env) catch {
    failed => return { code: 1, stdout: "", stderr: "\{failed.message()}\n", }
  }
  let out_gate = @async.Mutex()
  let err_gate = @async.Mutex()
  let adapter = Adapter::new({
    adapter_id,
    send: line => emit(@stdio.stdout, out_gate, line + "\n"),
    store: parts.store,
    observations: parts.observations,
    locks: parts.locks,
    review_home: @path.join([env.home(), "review-home"]),
    log: entry => emit(@stdio.stderr, err_gate, log_text(entry)),
  })
  @async.with_task_group(outer => {
    outer.spawn_bg(() => adapter.run_jobs())
    // The group ends only when every line being handled has ended, so a request in progress finishes before the adapter does.
    @async.with_task_group(handlers => {
      pump(adapter, handlers)
      adapter.close_input()
    })
    adapter.finish()
  })
  { code: 0, stdout: "", stderr: "", }
}
