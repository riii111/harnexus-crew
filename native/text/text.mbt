///|
/// The code points of a JS string, read as JS reads them with `[...text]`: a surrogate pair is one code point and an unpaired surrogate is itself.
pub fn code_points(text : String) -> Array[Int32] {
  let units = text.code_units()
  let points = []
  let mut at = 0
  while at < units.length() {
    let unit = units[at].to_int()
    let next = if at + 1 < units.length() { units[at + 1].to_int() } else { 0 }
    if unit >= 0xD800 && unit <= 0xDBFF && next >= 0xDC00 && next <= 0xDFFF {
      points.push(0x10000 + (unit - 0xD800) * 0x400 + (next - 0xDC00))
      at += 2
    } else {
      points.push(unit)
      at += 1
    }
  }
  points
}

///|
/// Unicode general category L, as the pinned Bun's `\p{L}` has it.
pub fn is_letter(code : Int32) -> Bool {
  in_ranges(letter_ranges, code)
}

///|
/// Unicode general category N, as the pinned Bun's `\p{N}` has it.
pub fn is_number(code : Int32) -> Bool {
  in_ranges(number_ranges, code)
}

///|
/// Python's `str.isspace` set, so a request the Python taskctl accepted is accepted alike.
/// It differs from JS whitespace: it has U+001C to U+001F and U+0085, and lacks U+FEFF.
pub fn is_space(code : Int32) -> Bool {
  (code >= 0x09 && code <= 0x0D) ||
  (code >= 0x1C && code <= 0x20) ||
  code == 0x85 ||
  code == 0xA0 ||
  code == 0x1680 ||
  (code >= 0x2000 && code <= 0x200A) ||
  code == 0x2028 ||
  code == 0x2029 ||
  code == 0x202F ||
  code == 0x205F ||
  code == 0x3000
}

///|
pub fn has_space(text : String) -> Bool {
  code_points(text).iter().any(is_space)
}

///|
/// True for the empty string, as `every` is for an empty list.
pub fn is_blank(text : String) -> Bool {
  code_points(text).iter().all(is_space)
}

///|
/// JS `String.prototype.trim`, whose whitespace set is not `is_space`.
pub fn js_trim(text : String) -> String {
  let units = text.code_units()
  let mut start = 0
  let mut end = units.length()
  while start < end && is_js_whitespace(units[start].to_int()) {
    start += 1
  }
  while end > start && is_js_whitespace(units[end - 1].to_int()) {
    end -= 1
  }
  if start == 0 && end == units.length() {
    return text
  }
  let out = StringBuilder()
  for index in start..<end {
    out.write_char(units[index].to_int().unsafe_to_char())
  }
  out.to_string()
}

///|
pub fn js_trim_end(text : String) -> String {
  let units = text.code_units()
  let mut end = units.length()
  while end > 0 && is_js_whitespace(units[end - 1].to_int()) {
    end -= 1
  }
  text[:end].to_owned()
}

///|
/// True when the text holds a character that JS `\s` matches, which is the set `js_trim` strips.
pub fn has_js_whitespace(text : String) -> Bool {
  text.code_units().iter().any(fn(unit) { is_js_whitespace(unit.to_int()) })
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
fn is_js_whitespace(unit : Int32) -> Bool {
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
fn in_ranges(ranges : FixedArray[Int32], code : Int32) -> Bool {
  let mut low = 0
  let mut high = ranges.length() / 2 - 1
  while low <= high {
    let middle = (low + high) / 2
    if code < ranges[middle * 2] {
      high = middle - 1
    } else if code > ranges[middle * 2 + 1] {
      low = middle + 1
    } else {
      return true
    }
  }
  false
}
