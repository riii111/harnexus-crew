///|
/// Sends one line to a Unix stream socket and returns what the peer answers before it closes, without trailing whitespace.
/// deadline   : Covers the connect, the write and the read.
/// empty line : Only probes; the connection proves the peer is alive and nothing is sent.
pub async fn exchange_line(
  path : String,
  line : String,
  timeout_ms : Int32,
) -> String raise @boundary.LineExchangeFailed {
  let target = @sys.c_string(path)
  // exchange_with refuses a path with a NUL before any attempt, so the unwrap only meets a path that has its C form.
  exchange_with(path, line, timeout_ms, fd => connect_once(fd, target.unwrap()))
}

///|
priv suberror ConnectFailed {
  ConnectFailed(Int32)
}

///|
/// Takes the connect attempt as an argument so a test can hold the connect still.
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
      @text.js_trim_end(@utf8.decode_lossy(stream.read_all()))
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

    // A Unix socket with a full listen queue gives no readiness notification, so retry after a short sleep.
    @async.sleep(10)
  }
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
