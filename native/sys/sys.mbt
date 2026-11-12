///|
/// The OS families the CLI supports.
pub enum Platform {
  Darwin
  Linux
  Other
}

///|
extern "C" fn platform_raw() -> Int32 = "harnexus_platform"

///|
#borrow(bytes)
extern "C" fn write_all_raw(fd : Int32, bytes : Bytes, len : Int32) -> Int32 = "harnexus_write_all"

///|
pub fn platform() -> Platform {
  match platform_raw() {
    1 => Darwin
    2 => Linux
    _ => Other
  }
}

///|
pub suberror WriteFailed {
  WriteFailed(fd~ : Int32, errno~ : Int32)
}

///|
/// Writes all of `text` as UTF-8 to a file descriptor the caller owns.
/// Raises with the errno of the failing write; a partial write is retried.
pub fn write_text(fd : Int32, text : String) -> Unit raise WriteFailed {
  let bytes = @utf8.encode(text)
  let errno = write_all_raw(fd, bytes, bytes.length())
  if errno != 0 {
    raise WriteFailed(fd~, errno~)
  }
}
