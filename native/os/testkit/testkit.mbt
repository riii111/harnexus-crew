///|
/// Unix socket servers, descriptor counts and process probes for the tests of the OS boundaries.
/// Only tests import this package, so none of it reaches the CLI.
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
fn c_string(text : String) -> Bytes {
  let bytes = @utf8.encode(text)
  Bytes::from_array(
    Array::makei(bytes.length() + 1, i => {
      if i < bytes.length() {
        bytes[i]
      } else {
        b'\x00'
      }
    }),
  )
}

///|
pub suberror Errno {
  Errno(Int32)
}

///|
/// A listening socket at `path`; the caller owns the descriptor.
pub fn listen(path : String, backlog~ : Int32 = 16) -> Int32 raise Errno {
  let fd = listen_raw(c_string(path), backlog)
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
  let fd = connect_raw(c_string(path))
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
  unlink_raw(c_string(path))
}

///|
/// How many descriptors this process holds.
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
/// The errno of a connect that finds the listen queue full.
pub fn eagain() -> Int32 {
  eagain_raw()
}

///|
pub fn fd_open(fd : Int32) -> Bool {
  fd_open_raw(fd) != 0
}
