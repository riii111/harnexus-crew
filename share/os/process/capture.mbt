///|
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
    // To keep a child being stopped from blocking on a full pipe, keep draining after the limit.
    if size.val > OUTPUT_LIMIT {
      on_limit()
    } else {
      into.write_bytes(chunk)
    }
  }
}
