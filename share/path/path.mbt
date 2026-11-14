///|
/// Same results as Node's `path.posix.join`.
pub fn join(parts : Array[String]) -> String {
  let kept = parts.filter(fn(part) { part != "" })
  if kept.is_empty() {
    "."
  } else {
    normalize(kept.join("/"))
  }
}

///|
/// Same results as Node's `path.posix.normalize`.
fn normalize(path : String) -> String {
  @core_path.Path(path).normalize().to_string()
}

///|
pub fn is_absolute(path : String) -> Bool {
  @core_path.Path(path).is_absolute()
}

///|
/// Same results as Node's `path.posix.dirname`.
pub fn dirname(path : String) -> String {
  @core_path.Path(path).dirname().to_string()
}

///|
/// Same results as Node's `path.posix.basename` without a suffix: the last component, trailing separators ignored.
pub fn basename(path : String) -> String {
  @core_path.Path(path).basename().to_owned()
}

///|
/// Same results as Node's `path.posix.resolve`, with the working directory given.
pub fn resolve(cwd~ : String, parts : Array[String]) -> String {
  let mut resolved = ""
  let mut absolute = false
  let mut index = parts.length() - 1
  while index >= -1 && !absolute {
    let part = if index >= 0 { parts[index] } else { cwd }
    index -= 1
    if part == "" {
      continue
    }
    resolved = part + "/" + resolved
    absolute = is_absolute(part)
  }
  let body = normalize(resolved)
  if body.length() > 1 && body.has_suffix("/") {
    body[:body.length() - 1].to_owned()
  } else {
    body
  }
}
