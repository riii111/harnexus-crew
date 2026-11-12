///|
/// Writes a value as `JSON.stringify(value, null, 1)` does: one space of indent per level, an empty array or object kept on one line.
fn stringify_indented(value : Json) -> String {
  let compact = @jsonio.stringify(value)
  let out = StringBuilder()
  let chars = compact.to_array()
  let mut depth = 0
  let mut in_string = false
  let mut escaped = false
  for at, char in chars {
    if in_string {
      out.write_char(char)
      if escaped {
        escaped = false
      } else if char == '\\' {
        escaped = true
      } else if char == '"' {
        in_string = false
      }
      continue
    }
    match char {
      '"' => {
        in_string = true
        out.write_char(char)
      }
      '{' | '[' => {
        out.write_char(char)
        let closes = at + 1 < chars.length() &&
          (chars[at + 1] == '}' || chars[at + 1] == ']')
        if !closes {
          depth += 1
          newline(out, depth)
        }
      }
      '}' | ']' => {
        let opened = at > 0 && (chars[at - 1] == '{' || chars[at - 1] == '[')
        if !opened {
          depth -= 1
          newline(out, depth)
        }
        out.write_char(char)
      }
      ',' => {
        out.write_char(char)
        newline(out, depth)
      }
      ':' => out.write_string(": ")
      _ => out.write_char(char)
    }
  }
  out.to_string()
}

///|
fn newline(out : StringBuilder, depth : Int32) -> Unit {
  out.write_char('\n')
  out.write_string(" ".repeat(depth))
}
