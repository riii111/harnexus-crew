///|
/// The directory part of a path: "." when there is none and "/" for the root.
/// Trailing separators are ignored, as `path.dirname` of Node does.
fn dirname(path : String) -> String {
  let trimmed = trim_trailing_separators(path)
  if trimmed == "" {
    return if path.has_prefix("/") { "/" } else { "." }
  }
  match trimmed.rev_find("/") {
    None => "."
    Some(at) => if at == 0 { "/" } else { trimmed[:at].to_owned() }
  }
}

///|
/// The last component of a path, without trailing separators.
fn basename(path : String) -> String {
  let trimmed = trim_trailing_separators(path)
  match trimmed.rev_find("/") {
    None => trimmed
    Some(at) => trimmed[at + 1:].to_owned()
  }
}

///|
/// The absolute, normalised form of a path: a relative one is taken from the working directory, and `.`, `..` and repeated separators are folded away.
fn resolve_path(path : String) -> String {
  let base = if path.has_prefix("/") {
    ""
  } else {
    @env.current_dir().unwrap_or("/")
  }
  let parts : Array[String] = []
  for part in "\{base}/\{path}".split("/") {
    match part.to_owned() {
      "" | "." => ()
      ".." => ignore(parts.pop())
      name => parts.push(name)
    }
  }
  "/" + parts.join("/")
}

///|
fn trim_trailing_separators(path : String) -> String {
  let mut end = path.length()
  while end > 0 && path[end - 1] == '/' {
    end -= 1
  }
  path[:end].to_owned()
}
