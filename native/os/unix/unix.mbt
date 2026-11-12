///|
extern "C" fn errno_index_raw(err : Int32) -> Int32 = "harnexus_errno_index"

///|
extern "C" fn close_fd_raw(fd : Int32) -> Int32 = "harnexus_close_fd"

///|
/// The code Node reports for an errno, such as `ENOENT`; `errno N` for one the boundaries do not meet.
pub fn errno_name(errno : Int32) -> String {
  match find(errno) {
    Some((name, _)) => name
    None => "errno \{errno}"
  }
}

///|
/// The text libuv attaches to the code, as in `ENOENT: no such file or directory`.
pub fn errno_message(errno : Int32) -> String {
  match find(errno) {
    Some((name, message)) => "\{name}: \{message}"
    None => "errno \{errno}"
  }
}

///|
/// Releases a descriptor the caller owns; a failure of close itself is not reported because the descriptor is gone either way.
pub fn close_fd(fd : Int32) -> Unit {
  ignore(close_fd_raw(fd))
}

///|
fn find(errno : Int32) -> (String, String)? {
  let index = errno_index_raw(errno)
  if index > 0 && index < names.length() {
    Some(names[index])
  } else {
    None
  }
}

///|
/// Indexed by `harnexus_errno_index`; position 0 is the unknown errno.
let names : Array[(String, String)] = [
  ("", ""),
  ("ENOENT", "no such file or directory"),
  ("EACCES", "permission denied"),
  ("EPERM", "operation not permitted"),
  ("ECONNREFUSED", "connection refused"),
  ("ECONNRESET", "connection reset by peer"),
  ("EPIPE", "broken pipe"),
  ("ETIMEDOUT", "connection timed out"),
  ("EAGAIN", "resource temporarily unavailable"),
  ("ENOTSOCK", "socket operation on non-socket"),
  ("ENAMETOOLONG", "name too long"),
  ("EMFILE", "too many open files"),
  ("ENFILE", "file table overflow"),
  ("ENOMEM", "not enough memory"),
  ("ENOTDIR", "not a directory"),
  ("ELOOP", "too many symbolic links encountered"),
  ("EIO", "i/o error"),
  ("ENOEXEC", "exec format error"),
  ("E2BIG", "argument list too long"),
  ("ETXTBSY", "text file is busy"),
  ("EISDIR", "illegal operation on a directory"),
  ("EINVAL", "invalid argument"),
  ("EADDRNOTAVAIL", "address not available"),
  ("EAFNOSUPPORT", "address family not supported"),
  ("EPROTOTYPE", "protocol wrong type for socket"),
  ("ENOBUFS", "no buffer space available"),
  ("EINTR", "interrupted system call"),
  ("EBADF", "bad file descriptor"),
  ("ENOTCONN", "socket is not connected"),
  ("EINPROGRESS", "operation in progress"),
  ("EALREADY", "connection already in progress"),
  ("EISCONN", "socket is already connected"),
  ("ECONNABORTED", "software caused connection abort"),
]
