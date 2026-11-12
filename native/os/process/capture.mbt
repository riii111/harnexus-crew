///|
/// The most output kept from a command, over stdout and stderr together.
const OUTPUT_LIMIT : Int32 = 16777216

///|
priv struct Capture {
  stdout : @buffer.Buffer
  stderr : @buffer.Buffer
  mut size : Int32
}

///|
fn Capture::new() -> Capture {
  { stdout: @buffer.Buffer(), stderr: @buffer.Buffer(), size: 0, }
}

///|
/// Reads a pipe to its end into `into`.
/// A chunk that takes the total past the limit calls `on_limit` and is dropped, and so is every later one; the pipe is still read so the command is never blocked on a full pipe while it is being stopped.
/// Bytes are decoded once at the end, so a character split across chunks stays whole.
async fn Capture::drain(
  self : Capture,
  slot : Fd,
  into : @buffer.Buffer,
  on_limit : () -> Unit,
) -> Unit {
  let stream = slot.stream()
  defer stream.close()
  while stream.read() is Some(chunk) {
    self.size += chunk.length()
    if self.size > OUTPUT_LIMIT {
      on_limit()
    } else {
      into.write_bytes(chunk)
    }
  }
}
