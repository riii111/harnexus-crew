///|
let open_read : Int32 = 0

///|
let open_exclusive : Int32 = 1

///|
let open_directory : Int32 = 3

///|
let kind_file : Int32 = 1

///|
let kind_directory : Int32 = 2

///|
let enoent : Int32 = 2

///|
let eexist : Int32 = 17

///|
let enotdir : Int32 = 20

///|
let einval : Int32 = 22

///|
fn open_path(path : String, how : Int32) -> Int32 {
  with_c_path(path, bytes => open_raw(bytes, how))
}

///|
fn stat_kind(path : String) -> Int32 {
  with_c_path(path, path_kind_raw)
}

///|
fn unlink_path(path : String) -> Int32 {
  with_c_path(path, unlink_raw)
}

///|
fn mkdir_path(path : String, mode : Int32) -> Int32 {
  with_c_path(path, bytes => mkdir_raw(bytes, mode))
}

///|
fn rename_path(from : String, to : String) -> Int32 {
  with_c_path(from, from_bytes => {
    with_c_path(to, to_bytes => rename_raw(from_bytes, to_bytes))
  })
}

///|
fn link_path(from : String, to : String) -> Int32 {
  with_c_path(from, from_bytes => {
    with_c_path(to, to_bytes => link_raw(from_bytes, to_bytes))
  })
}

///|
fn write_all_text(fd : Int32, text : String) -> Int32 {
  @sys.write_text(fd, text) catch {
    @sys.WriteFailed(errno~, ..) => return -errno
  }
  0
}

///|
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

///|
fn with_c_path(path : String, call : (Bytes) -> Int32) -> Int32 {
  match @sys.c_string(path) {
    Some(bytes) => call(bytes)
    None => -einval
  }
}

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
#borrow(bytes, digest)
extern "C" fn sha256_raw(bytes : Bytes, len : Int32, digest : FixedArray[Byte]) = "harnexus_store_sha256"
