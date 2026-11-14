///|
const OPEN : UInt16 = '{'

///|
const CLOSE : UInt16 = '}'

///|
/// An unknown name or a single brace fails.
/// `refuse` names what is wrong with a value at the place it goes, or returns None to accept it.
pub fn format(
  template : String,
  fields : Map[String, String],
  refuse~ : (String) -> String? = fn(_) { None },
) -> String raise @failure.TaskFailed {
  let units = template.code_units()
  let out = StringBuilder()
  let mut at = 0
  while at < units.length() {
    let unit = units[at]
    let next = if at + 1 < units.length() { units[at + 1] } else { 0 }
    if unit == OPEN && next == OPEN {
      out.write_char('{')
      at += 2
    } else if unit == CLOSE && next == CLOSE {
      out.write_char('}')
      at += 2
    } else if unit == OPEN {
      let close = closing_brace(units, at + 1)
      if close < 0 {
        @failure.fail("single '{' in template")
      }
      let name = template[at + 1:close].to_owned()
      out.write_string(field_value(name, fields, refuse))
      at = close + 1
    } else if unit == CLOSE {
      @failure.fail("single '}' in template")
    } else {
      let start = at
      while at < units.length() && units[at] != OPEN && units[at] != CLOSE {
        at += 1
      }
      out.write_view(template[start:at])
    }
  }
  out.to_string()
}

///|
pub fn escape_braces(text : String) -> String {
  text.replace_all(old="{", new="{{").replace_all(old="}", new="}}")
}

///|
/// For a value that goes inside a link target: a name, never a path, so none can lead the link to another folder or break it.
pub fn refuse_unless_name(value : String) -> String? {
  let units = value.code_units()
  if units.length() > 0 &&
    units
    .iter()
    .all(fn(unit) {
      @text.is_ascii_alphanumeric(unit.to_int()) || unit == '_' || unit == '-'
    }) {
    None
  } else {
    Some("may hold only letters, digits, _ and - inside a link target")
  }
}

///|
fn closing_brace(units : ArrayView[UInt16], from : Int32) -> Int32 {
  let mut index = from
  while index < units.length() {
    if units[index] == CLOSE {
      return index
    }
    if units[index] == OPEN {
      return -1
    }
    index += 1
  }
  -1
}

///|
fn field_value(
  name : String,
  fields : Map[String, String],
  refuse : (String) -> String?,
) -> String raise @failure.TaskFailed {
  guard fields.get(name) is Some(value) else {
    @failure.fail("unknown template field {\{name}}")
  }
  if refuse(value) is Some(reason) {
    @failure.fail("{\{name}} \{reason}")
  }
  value
}
