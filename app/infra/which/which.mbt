///|
/// Same results as `Bun.which`, so the TypeScript build and this one pick the same file.
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
    return anchor_path(strip_dot_slash(name), cwd).filter(runnable)
  }
  guard path_value is Some(value) else { return None }
  for entry in value.split(":") {
    let entry = entry.to_owned()
    if entry == "" {
      continue
    }
    if anchor_path(entry, cwd) is Some(dir) {
      let candidate = join_dir(dir, name)
      if runnable(candidate) {
        return Some(candidate)
      }
    }
  }
  None
}

///|
fn anchor_path(path : String, cwd : String?) -> String? {
  if path.has_prefix("/") {
    Some(path)
  } else {
    cwd.map(dir => join_dir(dir, path))
  }
}

///|
fn is_runnable_file(path : String) -> Bool {
  match @sys.c_string(path) {
    Some(terminated) => is_runnable_file_raw(terminated) == 1
    None => false
  }
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
