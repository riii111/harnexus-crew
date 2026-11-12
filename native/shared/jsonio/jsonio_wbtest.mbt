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
test "an unpaired surrogate escape is refused, not changed" {
  let refused = try {
    parse("\"\\ud800\"") |> ignore
    false
  } catch {
    JsonError(_) => true
  }
  inspect(refused, content="true")
  inspect(stringify(parse("\"\\ud83c\\udf19\"")), content="\"🌙\"")
}
