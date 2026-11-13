///|
/// Sends one line to a Unix stream socket and returns what the peer answers before it closes, without trailing whitespace.
/// One deadline covers the connect, the write and the read.
/// An empty line only probes: the connection proves the peer is alive and nothing is sent.
///
/// A failure before the connection was made leaves the line unsent (`connected` is false); any later failure leaves it unknown.
pub async fn exchange_line(
  path : String,
  line : String,
  timeout_ms : Int32,
) -> String raise @boundary.LineExchangeFailed {
  let target = path_bytes(path)
  exchange_with(path, line, timeout_ms, fd => connect_once(fd, target))
}

///|
/// The exchange with its connect attempt supplied, so a test can hold the connect still.
/// An attempt answers 0 once connected, else an errno.
async fn exchange_with(
  path : String,
  line : String,
  timeout_ms : Int32,
  attempt : (Int32) -> Int32,
) -> String raise @boundary.LineExchangeFailed {
  let failed = (code : String?, connected : Bool) => {
    @boundary.LineExchangeFailed(
      path~,
      code~,
      connected~,
      message="cannot reach \{path}",
    )
  }
  if path.contains("\u{0}") {
    raise failed(Some("ERR_INVALID_ARG_VALUE"), false)
  }
  let fd = open_raw()
  if fd < 0 {
    raise failed(Some(@unix.errno_name(-fd)), false)
  }
  let connected = Ref(false)
  // The descriptor is ours until a stream takes it, so an early timeout or failure closes it here.
  let taken = Ref(false)
  defer close_unless_taken(fd, taken)
  @async.with_timeout(timeout_ms, () => {
    connect_until_done(fd, attempt)
    connected.val = true
    taken.val = true
    let stream = @raw_fd.RawFdStream(fd)
    defer stream.close()
    if line == "" {
      ""
    } else {
      stream.write(@utf8.encode(line + "\n"))
      trim_end(@utf8.decode_lossy(stream.read_all()))
    }
  }) catch {
    @async.TimeoutError => raise failed(Some("ETIMEDOUT"), connected.val)
    ConnectFailed(errno) => raise failed(Some(@unix.errno_name(errno)), false)
    @os_error.OsError(_, raw_code~, ..) =>
      raise failed(Some(@unix.errno_name(raw_code)), connected.val)
    _ => raise failed(None, connected.val)
  }
}

///|
priv suberror ConnectFailed {
  ConnectFailed(Int32)
}

///|
/// Retries a non-blocking connect until it completes.
/// A Unix socket gives no readiness event for a full listen queue, so a pending attempt is retried after a short sleep that lets other tasks run.
async fn connect_until_done(
  fd : Int32,
  attempt : (Int32) -> Int32,
) -> Unit raise ConnectFailed {
  while true {
    let errno = attempt(fd)
    if errno == 0 {
      break
    }
    if connect_pending_raw(errno) == 0 {
      raise ConnectFailed(errno)
    }
    @async.sleep(10)
  }
}

///|
fn trim_end(text : String) -> String {
  let mut end = text.length()
  while end > 0 {
    let unit = text[end - 1]
    if is_js_space(unit.to_int()) {
      end -= 1
    } else {
      break
    }
  }
  text[:end].to_owned()
}

///|
/// The code units JavaScript's `trimEnd` removes: white space and line terminators.
fn is_js_space(unit : Int32) -> Bool {
  match unit {
    0x09
    | 0x0A
    | 0x0B
    | 0x0C
    | 0x0D
    | 0x20
    | 0xA0
    | 0x1680
    | 0x2028
    | 0x2029
    | 0x202F
    | 0x205F
    | 0x3000
    | 0xFEFF => true
    _ => unit >= 0x2000 && unit <= 0x200A
  }
}

///|
fn path_bytes(path : String) -> Bytes {
  let bytes = @utf8.encode(path)
  let out = Array::makei(bytes.length() + 1, i => {
    if i < bytes.length() {
      bytes[i]
    } else {
      b'\x00'
    }
  })
  Bytes::from_array(out)
}

///|
fn close_unless_taken(fd : Int32, taken : Ref[Bool]) -> Unit {
  if !taken.val {
    @unix.close_fd(fd)
  }
}

///|
extern "C" fn open_raw() -> Int32 = "harnexus_socket_open"

///|
#borrow(path)
extern "C" fn connect_once(fd : Int32, path : Bytes) -> Int32 = "harnexus_socket_connect"

///|
extern "C" fn connect_pending_raw(err : Int32) -> Int32 = "harnexus_socket_connect_pending"
