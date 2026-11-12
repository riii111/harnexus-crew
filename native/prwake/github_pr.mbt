///|
/// Whether the value is a github.com pull request URL, which is all the watch can see; a PR on another host is named but never linked.
/// Anything after the number must start with `/`, `?` or `#` and hold no whitespace, as when a URL is copied from the browser.
pub fn is_github_pr(value : String) -> Bool {
  let prefix = "https://github.com/"
  guard value.has_prefix(prefix) else { return false }
  let units = value.code_units().map(unit => unit.to_int())
  guard after_name(units, prefix.length()) is Some(repository) &&
    after_name(units, repository) is Some(pull) &&
    has_units(units, pull, "pull/") else {
    return false
  }
  let number = pull + 5
  guard number < units.length() &&
    units[number] >= '1'.to_int() &&
    units[number] <= '9'.to_int() else {
    return false
  }
  let mut end = number + 1
  while end < units.length() && is_digit(units[end]) {
    end += 1
  }
  if end == units.length() {
    return true
  }
  is_tail_start(units[end]) &&
  units[end + 1:].iter().all(unit => !is_js_space(unit))
}

///|
/// The position after a name of one or more characters GitHub allows and the slash that ends it.
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
  is_digit(unit) ||
  (unit >= 'A'.to_int() && unit <= 'Z'.to_int()) ||
  (unit >= 'a'.to_int() && unit <= 'z'.to_int()) ||
  unit == '_'.to_int() ||
  unit == '.'.to_int() ||
  unit == '-'.to_int()
}

///|
fn is_digit(unit : Int32) -> Bool {
  unit >= '0'.to_int() && unit <= '9'.to_int()
}

///|
fn is_tail_start(unit : Int32) -> Bool {
  unit == '/'.to_int() || unit == '?'.to_int() || unit == '#'.to_int()
}

///|
/// The whitespace of JavaScript's `\s`, which the TypeScript build's `\S` excludes.
fn is_js_space(unit : Int32) -> Bool {
  (unit >= 0x09 && unit <= 0x0D) ||
  unit == 0x20 ||
  unit == 0xA0 ||
  unit == 0x1680 ||
  (unit >= 0x2000 && unit <= 0x200A) ||
  unit == 0x2028 ||
  unit == 0x2029 ||
  unit == 0x202F ||
  unit == 0x205F ||
  unit == 0x3000 ||
  unit == 0xFEFF
}
