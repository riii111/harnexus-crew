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
test "stringify writes what JSON.stringify writes" {
  let text = "line\nquote\"back\\slash/ \u{0001}あ🌙"
  inspect(
    stringify(Json::string(text)),
    content="\"line\\nquote\\\"back\\\\slash/ \\u0001あ🌙\"",
  )
  inspect(stringify(Json::number(1.0)), content="1")
  inspect(stringify(Json::number(0.1)), content="0.1")
  inspect(stringify(Json::number(1000000000000000000000.0)), content="1e+21")
}
