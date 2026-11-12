///|
const MAX_DEPTH : Int32 = 1024

///|
priv struct Parser {
  units : ArrayView[UInt16]
  mut at : Int32
}

///|
fn parse_document(text : String) -> Json raise JsonError {
  let parser : Parser = { units: text.code_units(), at: 0, }
  parser.skip_space()
  let value = parser.value(MAX_DEPTH)
  parser.skip_space()
  if parser.at < parser.units.length() {
    raise parser.fail("unexpected character")
  }
  value
}

///|
fn Parser::fail(self : Parser, what : String) -> JsonError {
  JsonError("invalid JSON: \{what} at \{self.at}")
}

///|
fn Parser::peek(self : Parser) -> UInt16? {
  if self.at < self.units.length() {
    Some(self.units[self.at])
  } else {
    None
  }
}

///|
fn Parser::skip_space(self : Parser) -> Unit {
  while self.at < self.units.length() {
    let unit = self.units[self.at]
    if unit == ' ' || unit == '\t' || unit == '\n' || unit == '\r' {
      self.at += 1
    } else {
      break
    }
  }
}

///|
fn Parser::expect(self : Parser, unit : Char) -> Unit raise JsonError {
  if self.peek() != Some(unit.to_int().to_uint16()) {
    raise self.fail("expected \{unit}")
  }
  self.at += 1
}

///|
fn Parser::value(self : Parser, depth : Int32) -> Json raise JsonError {
  if depth == 0 {
    raise self.fail("nesting is too deep")
  }
  match self.peek() {
    None => raise self.fail("unexpected end")
    Some(unit) =>
      match unit.to_int().unsafe_to_char() {
        '{' => self.object(depth)
        '[' => self.array(depth)
        '"' => Json::string(self.string())
        't' => self.word("true", Json::boolean(true))
        'f' => self.word("false", Json::boolean(false))
        'n' => self.word("null", Json::null())
        '-' | '0'..<='9' => self.number()
        _ => raise self.fail("unexpected character")
      }
  }
}

///|
fn Parser::word(
  self : Parser,
  word : String,
  value : Json,
) -> Json raise JsonError {
  for index, unit in word.code_units() {
    if self.at + index >= self.units.length() ||
      self.units[self.at + index] != unit {
      raise self.fail("unexpected character")
    }
  }
  self.at += word.length()
  value
}

///|
fn Parser::object(self : Parser, depth : Int32) -> Json raise JsonError {
  self.at += 1
  let entries : Map[String, Json] = Map([])
  self.skip_space()
  if self.peek() == Some(0x7D) {
    self.at += 1
    return Json::object(entries)
  }
  while true {
    self.skip_space()
    if self.peek() != Some(0x22) {
      raise self.fail("expected a key")
    }
    let key = self.string()
    self.skip_space()
    self.expect(':')
    self.skip_space()
    // A repeated key keeps its first place and takes the last value, as in JS.
    entries[key] = self.value(depth - 1)
    self.skip_space()
    match self.peek() {
      Some(0x2C) => self.at += 1
      Some(0x7D) => {
        self.at += 1
        break
      }
      _ => raise self.fail("expected , or }")
    }
  }
  Json::object(entries)
}

///|
fn Parser::array(self : Parser, depth : Int32) -> Json raise JsonError {
  self.at += 1
  let items : Array[Json] = []
  self.skip_space()
  if self.peek() == Some(0x5D) {
    self.at += 1
    return Json::array(items)
  }
  while true {
    self.skip_space()
    items.push(self.value(depth - 1))
    self.skip_space()
    match self.peek() {
      Some(0x2C) => self.at += 1
      Some(0x5D) => {
        self.at += 1
        break
      }
      _ => raise self.fail("expected , or ]")
    }
  }
  Json::array(items)
}

///|
fn Parser::string(self : Parser) -> String raise JsonError {
  self.at += 1
  let units : Array[Int32] = []
  while true {
    guard self.at < self.units.length() else {
      raise self.fail("unterminated string")
    }
    let unit = self.units[self.at].to_int()
    if unit == 0x22 {
      self.at += 1
      break
    }
    if unit < 0x20 {
      raise self.fail("control character in string")
    }
    if unit != 0x5C {
      units.push(unit)
      self.at += 1
      continue
    }
    self.at += 1
    guard self.at < self.units.length() else {
      raise self.fail("unterminated string")
    }
    let escape = self.units[self.at].to_int().unsafe_to_char()
    self.at += 1
    match escape {
      '"' => units.push(0x22)
      '\\' => units.push(0x5C)
      '/' => units.push(0x2F)
      'b' => units.push(0x08)
      'f' => units.push(0x0C)
      'n' => units.push(0x0A)
      'r' => units.push(0x0D)
      't' => units.push(0x09)
      // Adjacent escapes of a high and a low surrogate end up as the pair they spell, and any other surrogate stays alone, as in JS.
      'u' => units.push(self.hex4())
      _ => raise self.fail("invalid escape")
    }
  }
  string_from_units(units)
}

///|
fn Parser::hex4(self : Parser) -> Int32 raise JsonError {
  let mut value = 0
  for _ in 0..<4 {
    guard self.at < self.units.length() else {
      raise self.fail("unterminated string")
    }
    let digit = match self.units[self.at].to_int().unsafe_to_char() {
      '0'..<='9' as c => c.to_int() - '0'.to_int()
      'a'..<='f' as c => c.to_int() - 'a'.to_int() + 10
      'A'..<='F' as c => c.to_int() - 'A'.to_int() + 10
      _ => raise self.fail("invalid \\u escape")
    }
    value = value * 16 + digit
    self.at += 1
  }
  value
}

///|
fn Parser::digits(self : Parser) -> Unit raise JsonError {
  let start = self.at
  while self.at < self.units.length() &&
        self.units[self.at] >= '0' &&
        self.units[self.at] <= '9' {
    self.at += 1
  }
  if self.at == start {
    raise self.fail("expected a digit")
  }
}

///|
fn Parser::number(self : Parser) -> Json raise JsonError {
  let start = self.at
  if self.peek() == Some(0x2D) {
    self.at += 1
  }
  if self.peek() == Some(0x30) {
    self.at += 1
  } else {
    self.digits()
  }
  if self.peek() == Some(0x2E) {
    self.at += 1
    self.digits()
  }
  if self.peek() == Some(0x65) || self.peek() == Some(0x45) {
    self.at += 1
    if self.peek() == Some(0x2B) || self.peek() == Some(0x2D) {
      self.at += 1
    }
    self.digits()
  }
  let token = StringBuilder()
  for index in start..<self.at {
    token.write_char(self.units[index].to_int().unsafe_to_char())
  }
  // The token has the JSON number grammar, so the standard parser only converts it to the nearest double.
  match (Some(@json.parse(token.to_string())) catch { _ => None }) {
    Some(Number(number, ..)) => Json::number(number)
    _ => raise self.fail("invalid number")
  }
}
