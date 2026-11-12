///|
/// The text is not JSON, or JSON of the wrong shape; the message names where.
pub suberror JsonError {
  JsonError(String)
}

///|
/// Parses like JS `JSON.parse`: a repeated key keeps its last value and numbers go through a double.
/// An unpaired surrogate escape such as "\ud800" is accepted and written back unchanged; see `hold_unpaired`.
pub fn parse(text : String) -> Json raise JsonError {
  @json.parse(hold_unpaired(text), reject_duplicate_keys=false) catch {
    error => raise JsonError("invalid JSON: \{error}")
  }
}

///|
/// One line, no indentation, written as JS `JSON.stringify` writes a parsed value.
/// A number is written from its double, never from the text it was read from, so 9007199254740993 becomes 9007199254740992 and 1e400 becomes null.
/// Keys that are array indexes come first in ascending order, then the others in the order they were added.
pub fn stringify(value : Json) -> String {
  let out = StringBuilder()
  write_value(out, value)
  out.to_string()
}

///|
fn write_value(out : StringBuilder, value : Json) -> Unit {
  match value {
    Null => out.write_string("null")
    True => out.write_string("true")
    False => out.write_string("false")
    Number(number, ..) => out.write_string(number_text(number))
    String(text) => write_quoted(out, text)
    Array(items) => {
      out.write_char('[')
      for index, item in items {
        if index > 0 {
          out.write_char(',')
        }
        write_value(out, item)
      }
      out.write_char(']')
    }
    Object(entries) => {
      out.write_char('{')
      let mut first = true
      for key in js_key_order(entries) {
        if !first {
          out.write_char(',')
        }
        first = false
        write_quoted(out, key)
        out.write_char(':')
        write_value(out, entries[key])
      }
      out.write_char('}')
    }
  }
}

///|
fn number_text(number : Double) -> String {
  // JSON.stringify writes -0 as 0 and a number JSON cannot hold as null.
  if number == 0.0 {
    "0"
  } else if number.is_nan() || number.is_inf() {
    "null"
  } else {
    // Double::to_string already writes the shortest digits in JS's layout, including the exponent form from 1e21 and below 1e-6.
    number.to_string()
  }
}

///|
fn write_quoted(out : StringBuilder, text : String) -> Unit {
  out.write_char('"')
  for char in text {
    match char {
      '"' => out.write_string("\\\"")
      '\\' => out.write_string("\\\\")
      '\n' => out.write_string("\\n")
      '\r' => out.write_string("\\r")
      '\t' => out.write_string("\\t")
      '\u{08}' => out.write_string("\\b")
      '\u{0C}' => out.write_string("\\f")
      _ =>
        if char.to_int() >= RESERVED_START {
          write_unit_escape(out, 0xD800 + char.to_int() - RESERVED_START)
        } else if char.to_int() < 0x20 {
          write_unit_escape(out, char.to_int())
        } else {
          out.write_char(char)
        }
    }
  }
  out.write_char('"')
}

///|
fn write_unit_escape(out : StringBuilder, unit : Int32) -> Unit {
  // JS writes the code in lower-case hexadecimal.
  out.write_string("\\u")
  out.write_char(hex_digit(unit / 4096))
  out.write_char(hex_digit(unit / 256 % 16))
  out.write_char(hex_digit(unit / 16 % 16))
  out.write_char(hex_digit(unit % 16))
}

///|
fn hex_digit(value : Int32) -> Char {
  "0123456789abcdef"[value].to_char().unwrap()
}

///|
/// A MoonBit String cannot hold an unpaired surrogate, which JS accepts in a JSON string.
/// The boundary holds each one as a code point of the last 2048 of plane 16, U+10F800 to U+10FFFF, and writes it back as the surrogate escape.
/// Text that really contains such a code point is refused, so the two can never be confused.
const RESERVED_START : Int32 = 0x10F800

///|
/// Turns every unpaired surrogate escape into its reserved code point before the text is parsed.
fn hold_unpaired(text : String) -> String raise JsonError {
  let chars = text.to_array()
  let count = chars.length()
  let out = StringBuilder()
  let mut at = 0
  while at < count {
    let char = chars[at]
    if char.to_int() >= RESERVED_START {
      raise JsonError(
        "invalid JSON: U+10F800 to U+10FFFF are reserved for unpaired surrogates",
      )
    }
    if char != '\\' || at + 1 >= count {
      out.write_char(char)
      at += 1
      continue
    }
    if chars[at + 1] != 'u' {
      // The escaped character is copied with its backslash, so an escaped backslash never starts a \u escape.
      out.write_char(char)
      out.write_char(chars[at + 1])
      at += 2
      continue
    }
    match unit_at(chars, at + 2) {
      Some(unit) if unit >= 0xD800 && unit <= 0xDFFF => {
        let low = if unit <= 0xDBFF &&
          at + 7 < count &&
          chars[at + 6] == '\\' &&
          chars[at + 7] == 'u' {
          unit_at(chars, at + 8)
        } else {
          None
        }
        match low {
          Some(low) if low >= 0xDC00 && low <= 0xDFFF => {
            if unit >= 0xDBFE {
              raise JsonError(
                "invalid JSON: U+10F800 to U+10FFFF are reserved for unpaired surrogates",
              )
            }
            for index in at..<(at + 12) {
              out.write_char(chars[index])
            }
            at += 12
          }
          _ => {
            out.write_char((RESERVED_START + unit - 0xD800).unsafe_to_char())
            at += 6
          }
        }
      }
      _ => {
        out.write_char(char)
        at += 1
      }
    }
  }
  out.to_string()
}

///|
/// The value of the four hex digits that start at `at`, or None.
fn unit_at(chars : Array[Char], at : Int32) -> Int32? {
  if at + 4 > chars.length() {
    return None
  }
  let mut value = 0
  for index in at..<(at + 4) {
    let digit = match chars[index] {
      '0'..<='9' as c => c.to_int() - '0'.to_int()
      'a'..<='f' as c => c.to_int() - 'a'.to_int() + 10
      'A'..<='F' as c => c.to_int() - 'A'.to_int() + 10
      _ => return None
    }
    value = value * 16 + digit
  }
  Some(value)
}

///|
/// For text that leaves JSON, such as standard output or a hash input: each unpaired surrogate becomes U+FFFD, which is what UTF-8 encoding does to it in JS.
pub fn lossy_text(text : String) -> String {
  let out = StringBuilder()
  for char in text {
    if char.to_int() >= RESERVED_START {
      out.write_char('\u{FFFD}')
    } else {
      out.write_char(char)
    }
  }
  out.to_string()
}

///|
/// The order JS lists the keys of an object in: array indexes ascending, then the rest as added.
fn js_key_order(entries : Map[String, Json]) -> Array[String] {
  let indexes : Array[(Int64, String)] = []
  let others : Array[String] = []
  for key, _ in entries {
    match array_index(key) {
      Some(index) => indexes.push((index, key))
      None => others.push(key)
    }
  }
  indexes.sort_by_key(pair => pair.0)
  let ordered = indexes.map(pair => pair.1)
  ordered.append(others)
  ordered
}

///|
/// The array index a key stands for: decimal digits without a leading zero, up to 2^32 - 2.
fn array_index(key : String) -> Int64? {
  let length = key.length()
  if length == 0 || length > 10 || (length > 1 && key[0] == '0') {
    return None
  }
  let mut value : Int64 = 0L
  for unit in key.code_units() {
    if unit < '0' || unit > '9' {
      return None
    }
    value = value * 10L + (unit - '0').to_int64()
  }
  if value <= 4294967294L {
    Some(value)
  } else {
    None
  }
}

///|
/// The pairs of a JSON object, read by taking them out.
/// What is left after every known item is taken is the unknown part, which an open boundary keeps and a strict one rejects.
pub struct Fields {
  priv context : String
  priv entries : Map[String, Json]
}

///|
/// `context` names the value in errors, such as "request" or "bridge answer".
pub fn Fields::from_json(
  value : Json,
  context~ : String,
) -> Fields raise JsonError {
  match value {
    Object(pairs) => {
      // The copy keeps the reader from changing a tree other code still holds.
      let entries = Map([])
      for key, item in pairs {
        entries[key] = item
      }
      { context, entries, }
    }
    _ => raise JsonError("\{context} must be a JSON object")
  }
}

///|
/// Takes a item out, or None when it is absent.
/// null is a value of its own, so `Some(Null)` stays distinct from None and each boundary decides what null means.
pub fn Fields::take(self : Fields, key : String) -> Json? {
  match self.entries.get(key) {
    Some(item) => {
      self.entries.remove(key)
      Some(item)
    }
    None => None
  }
}

///|
pub fn Fields::take_string(
  self : Fields,
  key : String,
) -> String raise JsonError {
  match self.take(key) {
    Some(String(text)) => text
    _ => raise self.wrong(key, "a string")
  }
}

///|
/// Only an absent item is None; null is the wrong type here.
pub fn Fields::take_optional_string(
  self : Fields,
  key : String,
) -> String? raise JsonError {
  match self.take(key) {
    None => None
    Some(String(text)) => Some(text)
    Some(_) => raise self.wrong(key, "a string")
  }
}

///|
pub fn Fields::take_bool(self : Fields, key : String) -> Bool raise JsonError {
  match self.take(key) {
    Some(True) => true
    Some(False) => false
    _ => raise self.wrong(key, "a boolean")
  }
}

///|
/// A JSON number that is a whole number a JS double holds exactly.
pub fn Fields::take_int(self : Fields, key : String) -> Int64 raise JsonError {
  match self.take(key) {
    Some(Number(number, ..)) if number == number.floor() &&
      number.abs() <= 9007199254740991.0 => number.to_int64()
    _ => raise self.wrong(key, "an integer")
  }
}

///|
pub fn Fields::take_array(
  self : Fields,
  key : String,
) -> Array[Json] raise JsonError {
  match self.take(key) {
    Some(Array(items)) => items
    _ => raise self.wrong(key, "an array")
  }
}

///|
pub fn Fields::take_object(
  self : Fields,
  key : String,
) -> Fields raise JsonError {
  match self.take(key) {
    Some(Object(_) as item) =>
      Fields::from_json(item, context="\{self.context}.\{key}")
    _ => raise self.wrong(key, "an object")
  }
}

///|
/// The unknown part, in the order it was written.
pub fn Fields::rest(self : Fields) -> Map[String, Json] {
  let copy = Map([])
  for key, item in self.entries {
    copy[key] = item
  }
  copy
}

///|
/// For a strict boundary: fails on the first item nobody took.
pub fn Fields::reject_unknown(self : Fields) -> Unit raise JsonError {
  for key, _ in self.entries {
    raise JsonError(
      "\{self.context} has an unknown field \{Json::string(key).stringify()}",
    )
  }
}

///|
/// Writes known pairs and then the unknown part kept from the input, so a field this program does not know survives a round trip.
/// A known item wins over an unknown one of the same key, which a correct reader never produces.
pub fn object_with_extra(
  known : Array[(String, Json)],
  extra : Map[String, Json],
) -> Json {
  let pairs = Map([])
  for key, item in extra {
    pairs[key] = item
  }
  for pair in known {
    let (key, item) = pair
    pairs[key] = item
  }
  Json::object(pairs)
}

///|
fn Fields::wrong(self : Fields, key : String, expected : String) -> JsonError {
  JsonError("\{self.context}.\{key} must be \{expected}")
}
