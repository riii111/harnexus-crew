///|
#borrow(path)
extern "C" fn open_raw(path : Bytes, how : Int32) -> Int32 = "harnexus_store_open"

///|
extern "C" fn close_raw(fd : Int32) -> Int32 = "harnexus_store_close"

///|
extern "C" fn fsync_raw(fd : Int32) -> Int32 = "harnexus_store_fsync"

///|
#borrow(buffer)
extern "C" fn read_raw(
  fd : Int32,
  buffer : FixedArray[Byte],
  len : Int32,
) -> Int32 = "harnexus_store_read"

///|
#borrow(bytes)
extern "C" fn write_all_raw(fd : Int32, bytes : Bytes, len : Int32) -> Int32 = "harnexus_store_write_all"

///|
extern "C" fn fd_kind_raw(fd : Int32) -> Int32 = "harnexus_store_fd_kind"

///|
#borrow(path)
extern "C" fn path_kind_raw(path : Bytes) -> Int32 = "harnexus_store_path_kind"

///|
#borrow(from, to)
extern "C" fn rename_raw(from : Bytes, to : Bytes) -> Int32 = "harnexus_store_rename"

///|
#borrow(from, to)
extern "C" fn link_raw(from : Bytes, to : Bytes) -> Int32 = "harnexus_store_link"

///|
#borrow(path)
extern "C" fn unlink_raw(path : Bytes) -> Int32 = "harnexus_store_unlink"

///|
#borrow(path)
extern "C" fn mkdir_raw(path : Bytes, mode : Int32) -> Int32 = "harnexus_store_mkdir"

///|
#borrow(path, out)
extern "C" fn realpath_raw(
  path : Bytes,
  out : FixedArray[Byte],
  cap : Int32,
) -> Int32 = "harnexus_store_realpath"

///|
#borrow(path, out)
extern "C" fn list_raw(
  path : Bytes,
  out : FixedArray[Byte],
  cap : Int32,
) -> Int32 = "harnexus_store_list"

///|
extern "C" fn pid_raw() -> Int32 = "harnexus_store_pid"

///|
extern "C" fn process_alive_raw(pid : Int32) -> Int32 = "harnexus_store_process_alive"

///|
#borrow(out)
extern "C" fn errno_name_raw(
  code : Int32,
  out : FixedArray[Byte],
  cap : Int32,
) -> Int32 = "harnexus_store_errno_name"

///|
#borrow(bytes, digest)
extern "C" fn sha256_raw(bytes : Bytes, len : Int32, digest : FixedArray[Byte]) = "harnexus_store_sha256"

///|
let einval : Int32 = 22

///|
/// The path as NUL-terminated UTF-8, or None for a path with a NUL, which the OS would read as a shorter path.
fn c_path(path : String) -> Bytes? {
  if path.contains("\u{0}") {
    return None
  }
  Some(@utf8.encode(path + "\u{0}"))
}

///|
/// Applies a path call, answering EINVAL for a path that cannot be handed to the OS.
fn at_path(path : String, call : (Bytes) -> Int32) -> Int32 {
  match c_path(path) {
    Some(bytes) => call(bytes)
    None => -einval
  }
}

///|
fn open_at(path : String, how : Int32) -> Int32 {
  at_path(path, bytes => open_raw(bytes, how))
}

///|
fn kind_at(path : String) -> Int32 {
  at_path(path, path_kind_raw)
}

///|
fn unlink_at(path : String) -> Int32 {
  at_path(path, unlink_raw)
}

///|
fn mkdir_at(path : String, mode : Int32) -> Int32 {
  at_path(path, bytes => mkdir_raw(bytes, mode))
}

///|
fn rename_at(from : String, to : String) -> Int32 {
  at_path(from, from_bytes => {
    at_path(to, to_bytes => rename_raw(from_bytes, to_bytes))
  })
}

///|
fn link_at(from : String, to : String) -> Int32 {
  at_path(from, from_bytes => {
    at_path(to, to_bytes => link_raw(from_bytes, to_bytes))
  })
}

///|
fn write_all_text(fd : Int32, text : String) -> Int32 {
  let bytes = @utf8.encode(text)
  write_all_raw(fd, bytes, bytes.length())
}

///|
/// The symbolic name of an errno, such as "ENOENT", or None for one this program does not name.
fn errno_code(errno : Int32) -> String? {
  let out : FixedArray[Byte] = FixedArray::make(32, b'\x00')
  let len = errno_name_raw(errno, out, 32)
  if len <= 0 {
    return None
  }
  Some(@utf8.decode_lossy(Bytes::from_array(out[:len])))
}

///|
/// Reads up to the end of the file behind `fd`; a negative result is the negated errno.
fn read_to_end(fd : Int32) -> Result[Bytes, Int32] {
  let collected = @buffer.Buffer()
  let chunk : FixedArray[Byte] = FixedArray::make(65536, b'\x00')
  while true {
    let read = read_raw(fd, chunk, 65536)
    if read < 0 {
      return Err(-read)
    }
    if read == 0 {
      break
    }
    collected.write_bytes(Bytes::from_array(chunk[:read]))
  }
  Ok(collected.to_bytes())
}
