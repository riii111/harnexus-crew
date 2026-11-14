///|
pub suberror Errno {
  Errno(Int32)
}

///|
/// A listening socket at `path`; the caller owns the descriptor.
pub fn listen(path : String, backlog~ : Int32 = 16) -> Int32 raise Errno {
  let fd = listen_raw(encode_c_string(path), backlog)
  if fd < 0 {
    raise Errno(-fd)
  }
  fd
}

///|
/// The next waiting connection, or None while there is none.
pub fn accept(listener : Int32) -> Int32? raise Errno {
  let fd = accept_raw(listener)
  if fd >= 0 {
    return Some(fd)
  }
  // EBADF is 9 on both systems; any other failure means no connection is waiting.
  if -fd == 9 {
    raise Errno(-fd)
  }
  None
}

///|
/// A client connection that stays open, queued on the listener; the errno when the queue refuses it.
pub fn connect_and_hold(path : String) -> Int32 raise Errno {
  let fd = connect_raw(encode_c_string(path))
  if fd < 0 {
    raise Errno(-fd)
  }
  fd
}

///|
pub fn close_fd(fd : Int32) -> Unit {
  ignore(close_raw(fd))
}

///|
pub fn remove_file(path : String) -> Unit {
  unlink_raw(encode_c_string(path))
}

///|
pub fn open_fds() -> Int32 {
  open_fds_raw()
}

///|
pub fn pid() -> Int32 {
  getpid_raw()
}

///|
/// Whether the process can still be signalled; a process that has exited but is not yet collected counts as alive.
pub fn alive(pid : Int32) -> Bool {
  alive_raw(pid) != 0
}

///|
pub fn eagain() -> Int32 {
  eagain_raw()
}

///|
pub fn fd_open(fd : Int32) -> Bool {
  fd_open_raw(fd) != 0
}

///|
pub fn is_macos() -> Bool {
  is_macos_raw() != 0
}

///|
/// The test runner's output goes through descriptors 0 to 2, so nothing may print or wait until `restore_stdio` is called with the result.
pub fn close_stdio() -> FixedArray[Int32] raise Errno {
  let saved = FixedArray::make(3, -1)
  let err = close_stdio_raw(saved)
  if err != 0 {
    raise Errno(err)
  }
  saved
}

///|
pub fn restore_stdio(saved : FixedArray[Int32]) -> Unit {
  restore_stdio_raw(saved)
}

///|
let gate : @async.Mutex = @async.Mutex()

///|
pub async fn serial(body : async () -> Unit) -> Unit {
  // The test driver runs up to ten tests at once on one thread, so a test that counts descriptors, times a deadline or counts a child's runs holds the gate to keep another test's sockets, children and sleeps out of it.
  gate.acquire()
  defer gate.release()
  body()
}

///|
/// The result of `work` and how many milliseconds it took.
pub async fn[T] timed(work : async () -> T) -> (T, Int32) {
  let started = @async.now()
  let value = work()
  (value, (@async.now() - started).to_int())
}

///|
pub fn assert_between(value : Int32, low : Int32, high : Int32) -> Unit raise {
  if value < low || value > high {
    fail("\{value} is outside \{low}..\{high}")
  }
}

///|
/// The temporary directory without a trailing slash.
pub fn temp_base() -> String {
  let base = @env.get_env_var("TMPDIR").unwrap_or("/tmp")
  if base.has_suffix("/") {
    base[:base.length() - 1].to_owned()
  } else {
    base
  }
}

///|
pub async fn scratch(name : String) -> String {
  @fs.tmpdir(prefix="hx-\{name}.")
}

///|
pub async fn remove_tree(path : String) -> Unit {
  @fs.rmdir(path, recursive=true, allow_missing=true)
}

///|
fn encode_c_string(text : String) -> Bytes {
  @sys.c_string(text).unwrap()
}

///|
#borrow(path)
extern "C" fn listen_raw(path : Bytes, backlog : Int32) -> Int32 = "harnexus_testkit_listen"

///|
extern "C" fn accept_raw(listener : Int32) -> Int32 = "harnexus_testkit_accept"

///|
#borrow(path)
extern "C" fn connect_raw(path : Bytes) -> Int32 = "harnexus_testkit_connect"

///|
extern "C" fn close_raw(fd : Int32) -> Int32 = "harnexus_testkit_close"

///|
#borrow(path)
extern "C" fn unlink_raw(path : Bytes) = "harnexus_testkit_unlink"

///|
extern "C" fn open_fds_raw() -> Int32 = "harnexus_testkit_open_fds"

///|
extern "C" fn getpid_raw() -> Int32 = "harnexus_testkit_getpid"

///|
extern "C" fn alive_raw(pid : Int32) -> Int32 = "harnexus_testkit_alive"

///|
extern "C" fn fd_open_raw(fd : Int32) -> Int32 = "harnexus_testkit_fd_open"

///|
extern "C" fn eagain_raw() -> Int32 = "harnexus_testkit_eagain"

///|
extern "C" fn is_macos_raw() -> Int32 = "harnexus_testkit_is_macos"

///|
#borrow(saved)
extern "C" fn close_stdio_raw(saved : FixedArray[Int32]) -> Int32 = "harnexus_testkit_close_stdio"

///|
#borrow(saved)
extern "C" fn restore_stdio_raw(saved : FixedArray[Int32]) = "harnexus_testkit_restore_stdio"
