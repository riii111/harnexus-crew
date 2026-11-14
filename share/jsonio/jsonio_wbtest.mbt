///|
test "parse keeps the last of a repeated key" {
  inspect(parse("{\"a\":1,\"a\":2}").stringify(), content="{\"a\":2}")
}

///|
test "parse fails with an invalid JSON message on text that is not JSON" {
  let message = try {
    parse("{") |> ignore
    "accepted"
  } catch {
    JsonError(message) => message
  }

  assert_eq(message.find("invalid JSON: "), Some(0))
}

///|
test "an unpaired surrogate escape reads as U+FFFD" {
  let cases : Array[(String, String)] = [
    ("\"\\ud800\"", "\u{FFFD}"),
    ("\"\\uDC00\"", "\u{FFFD}"),
    ("\"\\udc00\\ud800\"", "\u{FFFD}\u{FFFD}"),
    ("\"a\\ud800b\"", "a\u{FFFD}b"),
    ("\"\\ud83c\\u0041\"", "\u{FFFD}A"),
    ("\"\\\"\\ud800\"", "\"\u{FFFD}"),
  ]

  for pair in cases {
    let (input, expected) = pair
    match parse(input) {
      String(text) => assert_eq(text, expected, msg=input)
      _ => fail("not a string: \{input}")
    }
  }
}

///|
test "a surrogate pair escape reads as its character, also after an unpaired one" {
  let cases : Array[(String, String)] = [
    ("\"\\ud83c\\udf19\"", "\u{1F319}"),
    ("\"\\ud800\\ud83c\\udf19\"", "\u{FFFD}\u{1F319}"),
  ]

  for pair in cases {
    let (input, expected) = pair
    match parse(input) {
      String(text) => assert_eq(text, expected, msg=input)
      _ => fail("not a string: \{input}")
    }
  }
}

///|
test "an escaped backslash before ud800 stays literal text" {
  match parse("\"\\\\ud800\"") {
    String(text) => assert_eq(text, "\\ud800")
    _ => fail("not a string")
  }
}

///|
test "a key with an unpaired surrogate escape reads as U+FFFD" {
  inspect(
    parse("{\"\\ud800\":1,\"x\":\"\\udfff\"}").stringify(),
    content="{\"\u{FFFD}\":1,\"x\":\"\u{FFFD}\"}",
  )
}

///|
test "as_text gives a string as it is and any other value as JSON" {
  let cases : Array[(Json, String)] = [
    (Json::string("a\"b"), "a\"b"),
    (Json::number(3.0), "3"),
    (Json::null(), "null"),
    (Json::boolean(true), "true"),
    (parse("{\"a\":[1]}"), "{\"a\":[1]}"),
  ]

  for pair in cases {
    let (value, expected) = pair
    assert_eq(as_text(value), expected, msg=value.stringify())
  }
}
