///|
/// The text is not JSON, or JSON of the wrong shape; the message names where.
pub suberror JsonError {
  JsonError(String)
}

///|
/// Parses like JS `JSON.parse`: a repeated key keeps its last value, numbers go through a double, and a string may hold an unpaired surrogate.
/// Nesting deeper than 1024 levels is refused.
pub fn parse(text : String) -> Json raise JsonError {
  parse_document(text)
}

///|
/// One line, no indentation, written as JS `JSON.stringify` writes a parsed value.
/// A number is written from its double, never from the text it was read from, so 9007199254740993 becomes 9007199254740992 and 1e400 becomes null.
/// Keys that are array indexes come first in ascending order, then the others in the order they were added.
/// An unpaired surrogate is written as its escape, so what was read is written back as it was.
pub fn stringify(value : Json) -> String {
  let out = StringBuilder()
  write_value(out, value)
  out.to_string()
}

///|
/// For text that leaves JSON, such as standard output or a hash input: each unpaired surrogate becomes U+FFFD, which is what UTF-8 encoding does to it in JS.
pub fn lossy_text(text : String) -> String {
  let units = text.code_units()
  let out = StringBuilder()
  let mut at = 0
  while at < units.length() {
    let width = char_width(units, at)
    if width == 0 {
      out.write_char('\u{FFFD}')
      at += 1
    } else {
      for index in at..<(at + width) {
        out.write_char(units[index].to_int().unsafe_to_char())
      }
      at += width
    }
  }
  out.to_string()
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
