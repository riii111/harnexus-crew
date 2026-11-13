///|
async fn serve(env : @environment.Env, adapter_id : String) -> @run.CommandRun {
  let out_gate = @async.Mutex()
  let err_gate = @async.Mutex()
  let lines : Array[String] = []
  @delivery.serve(
    env,
    adapter_id,
    read_line=() => {
      if lines.is_empty() {
        let chunk = match
          (Ok(@stdio.stdin.read_until(b"\n")) catch { e => Err(e) }) {
          Ok(Some(bytes)) => @utf8.decode_lossy(bytes)
          _ => return None
        }
        lines.append(split_lines(chunk))
      }
      Some(lines.remove(0))
    },
    send=line => emit(@stdio.stdout, out_gate, line + "\n"),
    log=entry => emit(@stdio.stderr, err_gate, log_text(entry)),
  ) catch {
    @failure.TaskFailed(message) =>
      return { code: 1, stdout: "", stderr: "\{message}\n", }
    other => raise other
  }
  { code: 0, stdout: "", stderr: "", }
}

///|
async fn emit(
  stream : @stdio.Output,
  gate : @async.Mutex,
  text : String,
) -> Unit noraise {
  // To prevent concurrent tasks from mixing lines, hold the lock for the entire write.
  gate.acquire()
  defer gate.release()
  stream.write(@utf8.encode(text)) catch {
    // A closed output has no reporting channel, so discard the failed write.
    _ => ()
  }
}

///|
fn log_text(entry : Array[(String, Json)]) -> String {
  let line = [("time", Json::string(@store.now_iso())), ..entry]
  Json::object(Map::from_array(line)).stringify() + "\n"
}

///|
/// Split CRLF, LF and lone CR the same way as Node's readline.
fn split_lines(chunk : String) -> Array[String] {
  let text = if chunk.has_suffix("\r") {
    chunk[:chunk.length() - 1].to_owned()
  } else {
    chunk
  }
  text.split("\r").map(line => line.to_owned()).collect()
}
