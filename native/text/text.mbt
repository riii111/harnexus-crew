///|
/// The whitespace of JS `\s`, which `js_trim` strips.
pub fn is_space(unit : Int32) -> Bool {
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

///|
pub fn is_ascii_alphanumeric(unit : Int32) -> Bool {
  (unit >= 0x30 && unit <= 0x39) ||
  (unit >= 0x41 && unit <= 0x5A) ||
  (unit >= 0x61 && unit <= 0x7A)
}

///|
pub fn has_space(text : String) -> Bool {
  text.code_units().iter().any(unit => is_space(unit.to_int()))
}

///|
/// True for the empty string, as `every` is for an empty list.
pub fn is_blank(text : String) -> Bool {
  text.code_units().iter().all(unit => is_space(unit.to_int()))
}

///|
pub fn js_trim(text : String) -> String {
  let units = text.code_units()
  let mut start = 0
  let mut end = units.length()
  while start < end && is_space(units[start].to_int()) {
    start += 1
  }
  while end > start && is_space(units[end - 1].to_int()) {
    end -= 1
  }
  if start == 0 && end == units.length() {
    return text
  }
  text[start:end].to_owned()
}

///|
pub fn js_trim_end(text : String) -> String {
  let units = text.code_units()
  let mut end = units.length()
  while end > 0 && is_space(units[end - 1].to_int()) {
    end -= 1
  }
  text[:end].to_owned()
}

///|
/// JS `<` on strings: code unit by code unit, which differs from code point order for characters above U+FFFF.
pub fn compare_utf16(left : String, right : String) -> Int32 {
  let a = left.code_units()
  let b = right.code_units()
  let shared = if a.length() < b.length() { a.length() } else { b.length() }
  for index in 0..<shared {
    if a[index] != b[index] {
      return if a[index] < b[index] { -1 } else { 1 }
    }
  }
  a.length().compare(b.length())
}

///|
const EXCERPT_UNITS : Int32 = 500

///|
/// Output repeated in an error: the trimmed text, cut to name the cause without flooding the message.
pub fn excerpt(text : String) -> String {
  let trimmed = js_trim(text)
  if trimmed.length() <= EXCERPT_UNITS {
    return trimmed
  }
  // A cut through a surrogate pair would leave half of it, so that half becomes U+FFFD.
  if trimmed.code_unit_at(EXCERPT_UNITS - 1).to_int() is (0xD800..<=0xDBFF) {
    "\{trimmed[:EXCERPT_UNITS - 1]}\u{FFFD}"
  } else {
    trimmed[:EXCERPT_UNITS].to_owned()
  }
}
