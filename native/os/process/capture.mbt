///|
/// The most output kept from a command, for the streams a count covers.
const OUTPUT_LIMIT : Int32 = 16777216

///|
priv struct Capture {
  stdout : @buffer.Buffer
  stderr : @buffer.Buffer
}

///|
fn Capture::new() -> Capture {
  { stdout: @buffer.Buffer(), stderr: @buffer.Buffer(), }
}

///|
/// Reads a pipe to its end into `into`.
/// `size` counts the bytes read so far, and a chunk that takes it past the limit calls `on_limit` and is dropped, and so is every later one; the pipe is still read so the command is never blocked on a full pipe while it is being stopped.
/// Bytes are decoded once at the end, so a character split across chunks stays whole.
async fn drain(
  slot : Fd,
  into : @buffer.Buffer,
  size : Ref[Int32],
  on_limit : () -> Unit,
) -> Unit {
  let stream = slot.stream()
  defer stream.close()
  while stream.read() is Some(chunk) {
    size.val += chunk.length()
    if size.val > OUTPUT_LIMIT {
      on_limit()
    } else {
      into.write_bytes(chunk)
    }
  }
}
