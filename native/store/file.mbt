///|
/// What a file operation was doing when it failed.
/// `Sync` means the change was made but may not survive a crash.
pub(all) enum FileAction {
  Read
  Write
  Sync
  Remove
  Prepare
  Append
}

///|
/// A file operation that did not complete.
/// `code` is the symbolic errno such as "ENOENT", or None when the failure has no errno.
pub(all) suberror FileFailed {
  FileFailed(
    action~ : FileAction,
    path~ : String,
    code~ : String?,
    message~ : String
  )
}

///|
/// The failure as the user sees it: the message, then the errno code in parentheses.
pub fn FileFailed::user_message(self : FileFailed) -> String {
  let FileFailed(code~, message~, ..) = self
  match code {
    Some(code) => "\{message} (\{code})"
    None => message
  }
}

///|
/// Reads a file as text; None when it does not exist.
pub fn read_text_if_exists(path : String) -> String? raise FileFailed {
  let message = "cannot read \{path}"
  let fd = open_at(path, open_read)
  if fd == -enoent {
    return None
  }
  let fd = check(fd, Read, path, message)
  Some(decode_text(read_and_close(fd, path, message)))
}

///|
/// Reads a regular file as text.
/// A FIFO or device is refused, since reading it could wait forever.
pub fn read_regular_text(path : String) -> String raise FileFailed {
  let message = "cannot read \{path}"
  let fd = check(open_at(path, open_read), Read, path, message)
  let kind = fd_kind_raw(fd)
  if kind != kind_file {
    ignore(close_raw(fd))
    if kind < 0 {
      raise failure(Read, path, -kind, message)
    }
    raise FileFailed(action=Read, path~, code=None, message~)
  }
  decode_text(read_and_close(fd, path, message))
}

///|
/// Replaces the file with `content` so that a reader sees either the previous content or all of the new content.
/// A `Sync` failure means the new content is in place but its directory entry may not survive a crash.
pub fn write_atomic(path : String, content : String) -> Unit raise FileFailed {
  replace_file(path, content)
  sync_parent(path, "wrote")
}

///|
/// Creates the file with `content` unless one exists; false when it already exists.
/// Of several writers only one creates it, and only with its full content.
pub fn write_exclusive(
  path : String,
  content : String,
) -> Bool raise FileFailed {
  let message = "cannot write \{path}"
  let temporary = write_temporary(path, content)
  // Linking fails when a file already exists at the path, which is what lets exactly one writer create it.
  let linked = link_at(temporary, path)
  let removed = unlink_at(temporary)
  if linked < 0 && linked != -eexist {
    raise failure(Write, path, -linked, message)
  }
  if removed < 0 && removed != -enoent {
    raise failure(Write, path, -removed, message)
  }
  if linked < 0 {
    return false
  }
  sync_parent(path, "wrote")
  true
}

///|
/// Removes the file; a file that is already missing counts as removed.
/// A `Sync` failure means the file is gone but may come back after a crash.
pub fn remove_file(path : String) -> Unit raise FileFailed {
  let removed = unlink_at(path)
  if removed < 0 && removed != -enoent {
    raise failure(Remove, path, -removed, "cannot remove \{path}")
  }
  sync_parent(path, "removed")
}

///|
/// Creates the directory and its missing parents, owner-only.
pub fn prepare_directory(path : String) -> Unit raise FileFailed {
  let message = "cannot prepare directory \{path}"
  let made = make_directories(path)
  if made < 0 {
    raise failure(Prepare, path, -made, message)
  }
  // The parent is synced too, so files created inside later are not lost with a directory entry that never reached the disk.
  let synced = sync_directory(dirname(path))
  if synced < 0 {
    raise failure(Prepare, path, -synced, message)
  }
}

///|
/// Appends one line to a log kept by one writer at a time, and syncs it so a record of what was seen survives a crash.
pub fn append_line(path : String, line : String) -> Unit raise FileFailed {
  let message = "cannot append to \{path}"
  let made = make_directories(dirname(path))
  if made < 0 {
    raise failure(Append, path, -made, message)
  }
  let fd = check(open_at(path, open_append), Append, path, message)
  let written = write_all_text(fd, line + "\n")
  let synced = if written < 0 { written } else { fsync_raw(fd) }
  let closed = close_raw(fd)
  if written < 0 {
    raise failure(Append, path, -written, message)
  }
  if synced < 0 {
    raise failure(Append, path, -synced, message)
  }
  if closed < 0 {
    raise failure(Append, path, -closed, message)
  }
}

///|
/// The entry names of a directory in the order the OS lists them; None when the path is missing or not a directory.
pub fn list_directory_if_exists(
  path : String,
) -> Array[String]? raise FileFailed {
  list_with_capacity(path, 4096)
}

///|
pub fn is_file(path : String) -> Bool {
  kind_at(path) == kind_file
}

///|
pub fn is_directory(path : String) -> Bool {
  kind_at(path) == kind_directory
}

///|
pub fn path_exists(path : String) -> Bool {
  kind_at(path) > 0
}

///|
/// The absolute path with symbolic links resolved, or the absolute path as written when it cannot be resolved.
pub fn real_path_or_self(path : String) -> String {
  let absolute = resolve_path(path)
  let out : FixedArray[Byte] = FixedArray::make(4096, b'\x00')
  let len = match c_path(absolute) {
    Some(bytes) => realpath_raw(bytes, out, 4096)
    None => -einval
  }
  if len < 0 {
    return absolute
  }
  @utf8.decode_lossy(Bytes::from_array(out[:len]))
}

///|
let open_read : Int32 = 0

///|
let open_exclusive : Int32 = 1

///|
let open_append : Int32 = 2

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
let owner_only_directory : Int32 = 0o700

///|
fn failure(
  action : FileAction,
  path : String,
  errno : Int32,
  message : String,
) -> FileFailed {
  FileFailed(action~, path~, code=errno_code(errno), message~)
}

///|
/// Passes a non-negative result through and raises for a negated errno.
fn check(
  result : Int32,
  action : FileAction,
  path : String,
  message : String,
) -> Int32 raise FileFailed {
  if result < 0 {
    raise failure(action, path, -result, message)
  }
  result
}

///|
fn decode_text(bytes : Bytes) -> String {
  @utf8.decode_lossy(bytes[:])
}

///|
fn read_and_close(
  fd : Int32,
  path : String,
  message : String,
) -> Bytes raise FileFailed {
  let read = read_to_end(fd)
  let closed = close_raw(fd)
  match read {
    Err(errno) => raise failure(Read, path, errno, message)
    Ok(bytes) => {
      if closed < 0 {
        raise failure(Read, path, -closed, message)
      }
      bytes
    }
  }
}

///|
fn replace_file(path : String, content : String) -> Unit raise FileFailed {
  let temporary = write_temporary(path, content)
  // The rename happens only after the temporary file is flushed to disk, so a reader never sees a half-written file.
  let renamed = rename_at(temporary, path)
  if renamed < 0 {
    ignore(unlink_at(temporary))
    raise failure(Write, path, -renamed, "cannot write \{path}")
  }
}

///|
/// Writes `content` to a new owner-only file beside `path` and flushes it; the file is removed again when that fails.
fn write_temporary(path : String, content : String) -> String raise FileFailed {
  let message = "cannot write \{path}"
  let temporary = temporary_path(path)
  let fd = check(open_at(temporary, open_exclusive), Write, path, message)
  let written = write_all_text(fd, content)
  let synced = if written < 0 { written } else { fsync_raw(fd) }
  let closed = close_raw(fd)
  let errno = if written < 0 {
    written
  } else if synced < 0 {
    synced
  } else {
    closed
  }
  if errno < 0 {
    ignore(unlink_at(temporary))
    raise failure(Write, path, -errno, message)
  }
  temporary
}

///|
fn temporary_path(path : String) -> String {
  let name = ".\{basename(path)}.\{new_uuid()}.tmp"
  let directory = dirname(path)
  if directory == "." {
    name
  } else if directory.has_suffix("/") {
    directory + name
  } else {
    "\{directory}/\{name}"
  }
}

///|
fn sync_parent(path : String, done : String) -> Unit raise FileFailed {
  let synced = sync_directory(dirname(path))
  if synced < 0 {
    raise failure(
      Sync,
      path,
      -synced,
      "\{done} \{path} but cannot sync its directory",
    )
  }
}

///|
fn sync_directory(path : String) -> Int32 {
  let fd = open_at(path, open_directory)
  if fd < 0 {
    return fd
  }
  let synced = fsync_raw(fd)
  let closed = close_raw(fd)
  if synced < 0 {
    synced
  } else {
    closed
  }
}

///|
/// Creates a directory and its missing parents; an existing directory is fine, an existing file is EEXIST.
fn make_directories(path : String) -> Int32 {
  let made = mkdir_at(path, owner_only_directory)
  if made == -eexist {
    return if kind_at(path) == kind_directory { 0 } else { made }
  }
  if made != -enoent {
    return made
  }
  let parent = dirname(path)
  if parent == path {
    return made
  }
  let parent_made = make_directories(parent)
  if parent_made < 0 {
    return parent_made
  }
  let again = mkdir_at(path, owner_only_directory)
  if again == -eexist && kind_at(path) == kind_directory {
    0
  } else {
    again
  }
}

///|
/// Lists with a buffer of `capacity` bytes, retrying with the size the listing needs when it was too small.
fn list_with_capacity(
  path : String,
  capacity : Int32,
) -> Array[String]? raise FileFailed {
  let out : FixedArray[Byte] = FixedArray::make(capacity, b'\x00')
  let needed = match c_path(path) {
    Some(bytes) => list_raw(bytes, out, capacity)
    None => -einval
  }
  if needed == -enoent || needed == -enotdir {
    return None
  }
  if needed < 0 {
    raise failure(Read, path, -needed, "cannot list \{path}")
  }
  if needed > capacity {
    return list_with_capacity(path, needed)
  }
  Some(split_names(Bytes::from_array(out[:needed])))
}

///|
fn split_names(listing : Bytes) -> Array[String] {
  let names = []
  let mut start = 0
  for at in 0..<listing.length() {
    if listing[at] == b'\x00' {
      names.push(@utf8.decode_lossy(listing[start:at]))
      start = at + 1
    }
  }
  names
}
