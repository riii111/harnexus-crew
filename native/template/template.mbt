///|
/// An unknown name or a single brace fails, and the first problem found is reported.
/// `refuse` names what is wrong with a value at the place it goes, or returns None to accept it.
pub fn format(
  template : String,
  fields : Map[String, String],
  refuse~ : (String) -> String? = fn(_) { None },
) -> String raise @failure.TaskFailed {
  let units = template.code_units()
  let out = StringBuilder()
  let mut problem : String? = None
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
        problem = keep_first(problem, Some("single '{' in template"))
        out.write_char('{')
        at += 1
      } else {
        let name = template[at + 1:close].to_owned()
        problem = keep_first(problem, problem_of_field(name, fields, refuse))
        out.write_string(fields.get(name).unwrap_or("{" + name + "}"))
        at = close + 1
      }
    } else if unit == CLOSE {
      problem = keep_first(problem, Some("single '}' in template"))
      out.write_char('}')
      at += 1
    } else {
      let start = at
      while at < units.length() && units[at] != OPEN && units[at] != CLOSE {
        at += 1
      }
      out.write_view(template[start:at])
    }
  }
  match problem {
    Some(message) => @failure.fail(message)
    None => out.to_string()
  }
}

///|
pub fn escape_braces(text : String) -> String {
  text.replace_all(old="{", new="{{").replace_all(old="}", new="}}")
}

///|
/// For a value that goes inside a link target: a name, never a path, so none can lead the link to another folder or break it.
pub fn refuse_unless_name(value : String) -> String? {
  let points = @text.code_points(value)
  if points.length() > 0 &&
    points
    .iter()
    .all(fn(point) {
      @text.is_letter(point) ||
      @text.is_number(point) ||
      point == 0x5F ||
      point == 0x2D
    }) {
    None
  } else {
    Some("may hold only letters, digits, _ and - inside a link target")
  }
}

///|
const OPEN : UInt16 = 0x7B

///|
const CLOSE : UInt16 = 0x7D

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
fn problem_of_field(
  name : String,
  fields : Map[String, String],
  refuse : (String) -> String?,
) -> String? {
  match fields.get(name) {
    None => Some("unknown template field {\{name}}")
    Some(value) =>
      match refuse(value) {
        Some(reason) => Some("{\{name}} \{reason}")
        None => None
      }
  }
}

///|
fn keep_first(first : String?, later : String?) -> String? {
  match first {
    Some(_) => first
    None => later
  }
}
