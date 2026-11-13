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
    // 終了待ちの子が満杯のパイプで止まらないよう、上限を超えた後も読み捨てる。
    if size.val > OUTPUT_LIMIT {
      on_limit()
    } else {
      into.write_bytes(chunk)
    }
  }
}
