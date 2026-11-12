///|
test "parse keeps the last of a repeated key" {
  inspect(stringify(parse("{\"a\":1,\"a\":2}")), content="{\"a\":2}")
}

///|
test "parse rejects text that is not JSON" {
  let outcome = try {
    parse("{") |> ignore
    "accepted"
  } catch {
    JsonError(message) => message.has_prefix("invalid JSON: ").to_string()
  }
  inspect(outcome, content="true")
}

///|
test "unknown members survive a round trip" {
  let input = parse("{\"outcome\":\"done\",\"later\":{\"x\":[1,2]},\"a\":1}")
  let fields = Fields::from_json(input, context="answer")
  let outcome = fields.take_string("outcome")
  inspect(outcome, content="done")
  let output = object_with_extra(
    [("outcome", Json::string(outcome))],
    fields.rest(),
  )
  inspect(
    stringify(output),
    content="{\"later\":{\"x\":[1,2]},\"a\":1,\"outcome\":\"done\"}",
  )
}

///|
test "a strict boundary rejects the unknown part" {
  let fields = Fields::from_json(parse("{\"a\":1,\"b\":2}"), context="request")
  fields.take_int("a") |> ignore
  let message = try {
    fields.reject_unknown()
    "accepted"
  } catch {
    JsonError(message) => message
  }
  inspect(message, content="request has an unknown field \"b\"")
}

///|
test "absent and null differ" {
  let fields = Fields::from_json(parse("{\"a\":null}"), context="request")
  inspect(fields.take("a") is Some(Null), content="true")
  inspect(fields.take("b") is None, content="true")
}

///|
test "typed takes name the member that has the wrong type" {
  let fields = Fields::from_json(
    parse("{\"n\":1.5,\"s\":1}"),
    context="request",
  )
  let integer = try {
    fields.take_int("n") |> ignore
    "accepted"
  } catch {
    JsonError(message) => message
  }
  inspect(integer, content="request.n must be an integer")
  let text = try {
    fields.take_string("s") |> ignore
    "accepted"
  } catch {
    JsonError(message) => message
  }
  inspect(text, content="request.s must be a string")
}

///|
test "a round trip gives what JSON.parse then JSON.stringify give in JS" {
  let cases : Array[(String, String)] = [
    ("9007199254740993", "9007199254740992"),
    ("1e400", "null"),
    ("-1e400", "null"),
    ("-0", "0"),
    ("12345678901234567890", "12345678901234567000"),
    ("1E5", "100000"),
    ("0.1e1", "1"),
    ("1e-7", "1e-7"),
    ("0.000001", "0.000001"),
    ("1e21", "1e+21"),
    ("1e20", "100000000000000000000"),
    ("5e-324", "5e-324"),
    ("1.7976931348623157e308", "1.7976931348623157e+308"),
    ("{\"2\":2,\"1\":1}", "{\"1\":1,\"2\":2}"),
    (
      "{\"b\":1,\"a\":{\"10\":1,\"9\":2,\"x\":3,\"01\":4,\"4294967294\":5,\"4294967295\":6},\"0\":0}",
      "{\"0\":0,\"b\":1,\"a\":{\"9\":2,\"10\":1,\"4294967294\":5,\"x\":3,\"01\":4,\"4294967295\":6}}",
    ),
    (
      "[{\"2\":1,\"1\":[{\"3\":3,\"2\":2}]}]", "[{\"1\":[{\"2\":2,\"3\":3}],\"2\":1}]",
    ),
    (
      "\"\\u0001\\u001f\\b\\f\\n\\r\\t\\\"\\\\\\/\\u007f\\u2028\\u2029あ\\ud83c\\udf19\"",
      "\"\\u0001\\u001f\\b\\f\\n\\r\\t\\\"\\\\/\u{007f}\u{2028}\u{2029}あ🌙\"",
    ),
    ("{\"a\":1,\"b\":2,\"a\":3}", "{\"a\":3,\"b\":2}"),
  ]
  for pair in cases {
    let (input, expected) = pair
    inspect(stringify(parse(input)), content=expected)
  }
}

///|
test "unpaired surrogate escapes survive a round trip as JS writes them" {
  let cases : Array[(String, String)] = [
    ("\"\\ud800\"", "\"\\ud800\""),
    ("\"\\udc00\"", "\"\\udc00\""),
    ("\"\\udbff\"", "\"\\udbff\""),
    ("\"\\udfff\"", "\"\\udfff\""),
    ("\"\\udc00\\ud800\"", "\"\\udc00\\ud800\""),
    ("\"a\\ud800b\"", "\"a\\ud800b\""),
    (
      "{\"\\ud800\":1,\"\\udc00\":2,\"x\":3}", "{\"\\ud800\":1,\"\\udc00\":2,\"x\":3}",
    ),
    ("\"\\ud83c\\udf19\"", "\"🌙\""),
    ("\"\\ud83c\\u0041\"", "\"\\ud83cA\""),
    ("\"\\\\ud800\"", "\"\\\\ud800\""),
    ("\"\\ud800\\ud83c\\udf19\"", "\"\\ud800🌙\""),
    ("\"\\ud83c\\udf19\\udf19\"", "\"🌙\\udf19\""),
    ("[\"\\ud800\",\"\\udfff\"]", "[\"\\ud800\",\"\\udfff\"]"),
    ("\"\\udbfd\\udfff\"", "\"􏟿\""),
    ("\"\\uD800\"", "\"\\ud800\""),
  ]
  for pair in cases {
    let (input, expected) = pair
    inspect(stringify(parse(input)), content=expected)
  }
}

///|
test "code points near the old reserved range and unpaired surrogates stay apart" {
  let cases : Array[(String, String)] = [
    ("\"\u{10f800}\"", "\"\u{10f800}\""),
    ("\"\u{10ffff}\"", "\"\u{10ffff}\""),
    ("\"\u{10f900}\"", "\"\u{10f900}\""),
    ("\"\\udbfe\\udc00\"", "\"\u{10f800}\""),
    ("\"\\udbff\\udfff\"", "\"\u{10ffff}\""),
    ("\"\\udbfe\\udd00\"", "\"\u{10f900}\""),
    (
      "{\"\u{10f800}\":1,\"\\udbff\\udfff\":2,\"\\ud800\":3}", "{\"\u{10f800}\":1,\"\u{10ffff}\":2,\"\\ud800\":3}",
    ),
    ("\"\\udbfe\\udc00\\ud800\"", "\"\u{10f800}\\ud800\""),
    ("\"\\ud800\\udbfe\\udc00\"", "\"\\ud800\u{10f800}\""),
    ("\"\u{10f800}\\udc00\u{10ffff}\"", "\"\u{10f800}\\udc00\u{10ffff}\""),
    ("\"\\udbff\\udfff\\udbff\"", "\"\u{10ffff}\\udbff\""),
  ]
  for pair in cases {
    let (input, expected) = pair
    inspect(stringify(parse(input)), content=expected)
  }
}

///|
test "a string built in code keeps every code point" {
  inspect(
    stringify(Json::string("\u{10F800}\u{10FFFF}")),
    content="\"\u{10f800}\u{10ffff}\"",
  )
}

///|
test "an unpaired surrogate behaves as an ordinary string value" {
  let one = parse("\"\\ud800\"")
  let two = parse("{\"\\ud800\":1}")
  match (one, two) {
    (String(text), Object(entries)) => {
      inspect(text == string_from_units([0xD800]), content="true")
      inspect(entries.get(text) is Some(Number(1.0, ..)), content="true")
      inspect(text.length(), content="1")
      inspect((text + "x").length(), content="2")
    }
    _ => fail("unexpected shape")
  }
}

///|
test "lossy_text turns an unpaired surrogate into U+FFFD as UTF-8 encoding does" {
  match parse("\"a\\ud800b\\udc00\\ud83c\\udf19\"") {
    String(value) =>
      inspect(lossy_text(value), content="a\u{fffd}b\u{fffd}\u{1f319}")
    _ => fail("not a string")
  }
}

///|
test "malformed JSON is refused" {
  let bad = [
    "", "{", "[1,]", "{\"a\":}", "01", "1.", ".5", "+1", "\"a", "\"\\x\"", "\"\\u12\"",
    "tru", "nul", "[1] 2", "{'a':1}", "\"\u{01}\"", "[", "{\"a\" 1}", "-", "1e",
    "NaN",
  ]
  for text in bad {
    let refused = try {
      parse(text) |> ignore
      false
    } catch {
      JsonError(_) => true
    }
    inspect(refused, content="true")
  }
}

///|
test "nesting past the limit is refused and the limit itself is accepted" {
  let deep = fn(depth : Int32) { "[".repeat(depth) + "]".repeat(depth) }
  inspect(stringify(parse(deep(1024))).length(), content="2048")
  let refused = try {
    parse(deep(1025)) |> ignore
    false
  } catch {
    JsonError(_) => true
  }
  inspect(refused, content="true")
}
