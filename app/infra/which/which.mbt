///|
/// Finds a program the way `Bun.which` does, so the TypeScript build and this one pick the same file.
/// PATH is read from `env`.
/// A relative PATH entry or name is taken from the working directory, an empty entry is skipped, and a path that is not a runnable regular file is passed over.
/// The result is the entry and the name joined as written, so it is neither normalised nor resolved through links.
pub fn in_env(env : @environment.Env) -> (String) -> String? {
  let path_value = env.get("PATH")
  let cwd = @env.current_dir()
  name => find(name, path_value, cwd, is_runnable_file)
}

///|
fn find(
  name : String,
  path_value : String?,
  cwd : String?,
  runnable : (String) -> Bool,
) -> String? {
  if name == "" {
    return None
  }
  if name.contains("/") {
    let candidate = if name.has_prefix("/") {
      Some(name)
    } else {
      cwd.map(dir => join_dir(dir, strip_dot_slash(name)))
    }
    return candidate.filter(runnable)
  }
  guard path_value is Some(value) else { return None }
  for entry in value.split(":") {
    let entry = entry.to_owned()
    if entry == "" {
      continue
    }
    let dir = if entry.has_prefix("/") {
      Some(entry)
    } else {
      cwd.map(base => join_dir(base, entry))
    }
    match dir {
      Some(dir) => {
        let candidate = join_dir(dir, name)
        if runnable(candidate) {
          return Some(candidate)
        }
      }
      None => ()
    }
  }
  None
}

///|
fn is_runnable_file(path : String) -> Bool {
  if path.contains("\u{0}") {
    return false
  }
  let bytes = @utf8.encode(path)
  let terminated = Bytes::from_array(
    Array::makei(bytes.length() + 1, i => {
      if i < bytes.length() {
        bytes[i]
      } else {
        b'\x00'
      }
    }),
  )
  is_runnable_file_raw(terminated) == 1
}

///|
fn join_dir(dir : String, name : String) -> String {
  let mut end = dir.length()
  while end > 1 && dir[end - 1] == '/' {
    end -= 1
  }
  if end == 1 && dir[0] == '/' {
    "/\{name}"
  } else {
    "\{dir[:end]}/\{name}"
  }
}

///|
fn strip_dot_slash(name : String) -> String {
  if name.has_prefix("./") {
    name[2:].to_owned()
  } else {
    name
  }
}

///|
#borrow(path)
extern "C" fn is_runnable_file_raw(path : Bytes) -> Int32 = "harnexus_is_runnable_file"
