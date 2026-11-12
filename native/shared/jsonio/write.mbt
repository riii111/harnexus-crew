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
  let units = text.code_units()
  out.write_char('"')
  let mut at = 0
  while at < units.length() {
    let unit = units[at].to_int()
    let width = char_width(units, at)
    if width == 0 {
      write_unit_escape(out, unit)
    } else if width == 2 {
      out.write_char(unit.unsafe_to_char())
      out.write_char(units[at + 1].to_int().unsafe_to_char())
    } else {
      match unit {
        0x22 => out.write_string("\\\"")
        0x5C => out.write_string("\\\\")
        0x0A => out.write_string("\\n")
        0x0D => out.write_string("\\r")
        0x09 => out.write_string("\\t")
        0x08 => out.write_string("\\b")
        0x0C => out.write_string("\\f")
        _ =>
          if unit < 0x20 {
            write_unit_escape(out, unit)
          } else {
            out.write_char(unit.unsafe_to_char())
          }
      }
    }
    at += if width == 0 { 1 } else { width }
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
