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
pub fn normalize(path : String) -> String {
  if path == "" {
    return "."
  }
  let absolute = is_absolute(path)
  let trailing = path.has_suffix("/")
  let body = clean_segments(path, allow_above_root=!absolute)
  if body == "" {
    return if absolute { "/" } else if trailing { "./" } else { "." }
  }
  let suffixed = if trailing { body + "/" } else { body }
  if absolute {
    "/" + suffixed
  } else {
    suffixed
  }
}

///|
pub fn is_absolute(path : String) -> Bool {
  path.has_prefix("/")
}

///|
/// Same results as Node's `path.posix.dirname`.
pub fn dirname(path : String) -> String {
  if path == "" {
    return "."
  }
  let units = path.code_units()
  let rooted = units[0] == 0x2F
  let mut end = -1
  let mut matched_slash = true
  let mut index = units.length() - 1
  while index >= 1 {
    if units[index] == 0x2F {
      if !matched_slash {
        end = index
        break
      }
    } else {
      matched_slash = false
    }
    index -= 1
  }
  if end == -1 {
    return if rooted { "/" } else { "." }
  }
  if rooted && end == 1 {
    return "//"
  }
  path[:end].to_owned()
}

///|
/// Same results as Node's `path.posix.basename` without a suffix: the last component, trailing separators ignored.
pub fn basename(path : String) -> String {
  let mut end = path.length()
  while end > 0 && path[end - 1] == '/' {
    end -= 1
  }
  let trimmed = path[:end]
  match trimmed.rev_find("/") {
    None => trimmed.to_owned()
    Some(at) => trimmed[at + 1:].to_owned()
  }
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
  let body = clean_segments(resolved, allow_above_root=!absolute)
  if absolute {
    "/" + body
  } else if body == "" {
    "."
  } else {
    body
  }
}

///|
fn clean_segments(path : String, allow_above_root~ : Bool) -> String {
  let kept : Array[String] = []
  for segment in path.split("/") {
    let segment = segment.to_owned()
    if segment == "" || segment == "." {
      continue
    }
    if segment != ".." {
      kept.push(segment)
    } else if kept.length() > 0 && kept[kept.length() - 1] != ".." {
      let _ = kept.pop()
    } else if allow_above_root {
      kept.push("..")
    }
  }
  kept.join("/")
}
