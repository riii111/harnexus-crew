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

///|
/// The text as NUL-terminated UTF-8 for a C call, or None for text with a NUL, which C would read as a shorter string.
pub fn c_string(text : String) -> Bytes? {
  if text.contains("\u{0}") {
    return None
  }

  Some(@utf8.encode(text + "\u{0}"))
}

///|
#borrow(bytes)
extern "C" fn write_all_raw(fd : Int32, bytes : Bytes, len : Int32) -> Int32 = "harnexus_write_all"
