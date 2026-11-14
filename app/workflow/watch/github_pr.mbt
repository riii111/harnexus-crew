///|
pub const NOT_LINKABLE : String = "the PR watch needs the URL https://github.com/<owner>/<repo>/pull/<number>"

///|
/// The number of a github.com pull request URL, None for anything else.
/// Anything after the number must start with `/`, `?` or `#` and hold no whitespace, as when a URL is copied from the browser.
pub fn github_pr_number(value : String) -> String? {
  let prefix = "https://github.com/"
  guard value.has_prefix(prefix) else { return None }
  let units = value.code_units().map(unit => unit.to_int())
  guard after_name(units, prefix.length()) is Some(repository) &&
    after_name(units, repository) is Some(pull) &&
    has_units(units, pull, "pull/") else {
    return None
  }
  let number = pull + 5
  guard number < units.length() &&
    units[number] >= '1'.to_int() &&
    units[number] <= '9'.to_int() else {
    return None
  }
  let mut end = number + 1
  while end < units.length() && is_digit(units[end]) {
    end += 1
  }
  if end == units.length() ||
    (
      is_tail_start(units[end]) &&
      units[end + 1:].iter().all(unit => !@text.is_space(unit))
    ) {
    Some(value[number:end].to_owned())
  } else {
    None
  }
}

///|
fn is_github_pr(value : String) -> Bool {
  github_pr_number(value) is Some(_)
}

///|
fn after_name(units : Array[Int32], from : Int32) -> Int32? {
  let mut end = from
  while end < units.length() && is_name_char(units[end]) {
    end += 1
  }
  if end > from && end < units.length() && units[end] == '/'.to_int() {
    Some(end + 1)
  } else {
    None
  }
}

///|
fn is_tail_start(unit : Int32) -> Bool {
  unit == '/'.to_int() || unit == '?'.to_int() || unit == '#'.to_int()
}

///|
fn has_units(units : Array[Int32], at : Int32, text : String) -> Bool {
  let wanted = text.code_units()
  if at + wanted.length() > units.length() {
    return false
  }
  for offset in 0..<wanted.length() {
    if units[at + offset] != wanted[offset].to_int() {
      return false
    }
  }
  true
}

///|
fn is_name_char(unit : Int32) -> Bool {
  @text.is_ascii_alphanumeric(unit) ||
  unit == '_'.to_int() ||
  unit == '.'.to_int() ||
  unit == '-'.to_int()
}

///|
fn is_digit(unit : Int32) -> Bool {
  unit >= '0'.to_int() && unit <= '9'.to_int()
}
