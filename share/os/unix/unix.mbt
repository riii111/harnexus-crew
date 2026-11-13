///|
/// The symbolic name of an errno, such as `ENOENT`, or `errno N` for one the table does not name.
pub fn errno_name(errno : Int32) -> String {
  let out : FixedArray[Byte] = FixedArray::make(32, b'\x00')
  let len = errno_name_raw(errno, out, 32)
  if len <= 0 {
    return "errno \{errno}"
  }
  @utf8.decode_lossy(Bytes::from_array(out[:len]))
}

///|
/// Releases a descriptor the caller owns; a failure of close itself is not reported because the descriptor is gone either way.
pub fn close_fd(fd : Int32) -> Unit {
  ignore(close_fd_raw(fd))
}

///|
#borrow(out)
extern "C" fn errno_name_raw(
  errno : Int32,
  out : FixedArray[Byte],
  cap : Int32,
) -> Int32 = "harnexus_errno_name"

///|
extern "C" fn close_fd_raw(fd : Int32) -> Int32 = "harnexus_close_fd"
