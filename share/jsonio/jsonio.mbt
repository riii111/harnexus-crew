///|
pub suberror JsonError {
  JsonError(String)
}

///|
/// unpaired surrogate: An escaped surrogate without a partner reads as U+FFFD, so every String encodes to UTF-8.
/// repeated key      : Keeps the last value.
/// nesting           : Deeper than 1024 levels is refused.
pub fn parse(text : String) -> Json raise JsonError {
  @json.parse(replace_unpaired_escapes(text)) catch {
    error => raise JsonError("invalid JSON: \{error}")
  }
}

///|
/// A member of a record, Null when the record has none or is not an object.
pub fn field(record : Json, key : String) -> Json {
  match record {
    Object(members) => members.get(key).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
/// A string as it is, any other value as JSON.
pub fn as_text(value : Json) -> String {
  match value {
    String(text) => text
    other => other.stringify()
  }
}

///|
fn replace_unpaired_escapes(text : String) -> String {
  let units = text.code_units()
  let out = StringBuilder()
  let mut copied = 0
  let mut in_string = false
  let mut at = 0
  while at < units.length() {
    let unit = units[at]
    if unit == '"' {
      in_string = !in_string
    } else if in_string && unit == '\\' {
      match surrogate_escape(units, at) {
        Some(0xD800..<=0xDBFF) if surrogate_escape(units, at + 6)
          is Some(0xDC00..<=0xDFFF) => at += 12
        // JS can emit unpaired surrogates, so replace them before the standard parser rejects the whole document.
        Some(_) => {
          out.write_view(text.exact_view(start=copied, end=at))
          out.write_string("\\ufffd")
          at += 6
          copied = at
        }
        // The unit after the backslash is escaped, so a `"` there does not close the string.
        None => at += 2
      }
      continue
    }
    at += 1
  }
  if copied == 0 {
    return text
  }
  out.write_view(text.exact_view(start=copied))
  out.to_string()
}

///|
fn surrogate_escape(units : ArrayView[UInt16], at : Int32) -> Int32? {
  guard at + 6 <= units.length() && units[at] == '\\' && units[at + 1] == 'u' else {
    return None
  }
  let mut code = 0
  for unit in units[at + 2:at + 6] {
    let digit = match unit.to_int().unsafe_to_char() {
      '0'..<='9' as c => c.to_int() - '0'.to_int()
      'a'..<='f' as c => c.to_int() - 'a'.to_int() + 10
      'A'..<='F' as c => c.to_int() - 'A'.to_int() + 10
      _ => return None
    }
    code = code * 16 + digit
  }
  if code is (0xD800..<=0xDFFF) {
    Some(code)
  } else {
    None
  }
}
