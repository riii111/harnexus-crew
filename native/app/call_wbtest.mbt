///|
/// A bridge that records the lines it receives and answers each by `rule`, or not at all for None.
async fn with_bridge(
  name : String,
  rule : (String) -> String?,
  body : async (String, Array[String]) -> Unit,
) -> Unit {
  let lines = []
  with_server(
    name,
    stream => {
      let line = read_request(stream).unwrap_or("")
      lines.push(line)
      match rule(line) {
        Some(reply) => stream.write(@utf8.encode(reply + "\n"))
        // A bridge that does not answer keeps the connection open.
        None => @async.sleep(60000)
      }
    },
    path => body(path, lines),
  )
}

///|
fn bridge_env(path : String) -> @environment.Env {
  env_of([("HARNEXUS_CALL_SOCKET", path), ("HOME", "/nonexistent")])
}

///|
async fn call_json(
  env : @environment.Env,
  tool : String,
  args : Map[String, Json],
  timeout_ms? : Int32,
) -> String {
  let answer = match timeout_ms {
    Some(limit) => call_app(env, "w1", tool, args, timeout_ms=limit)
    None => call_app(env, "w1", tool, args)
  }
  json_text(answer.to_json())
}

///|
async test "sends the call with protocol 1 and answers without the version" {
  with_bridge(
    "call-1",
    _ => Some("{\"version\":1,\"outcome\":\"done\",\"result\":{}}"),
    (path, lines) => {
      let answer = call_json(bridge_env(path), "name_thread", {
        "name": Json::string("Impl TR1"),
      })
      assert_eq(answer, "{\"outcome\":\"done\",\"result\":{}}")
      assert_eq(lines.length(), 1)
      assert_eq(
        lines[0],
        "{\"version\":1,\"threadId\":\"w1\",\"tool\":\"name_thread\",\"arguments\":{\"name\":\"Impl TR1\"}}",
      )
    },
  )
}

///|
async test "a bridge's answer keeps every field and the order it was written in" {
  with_bridge(
    "call-2",
    _ => {
      Some(
        "{\"version\":1,\"result\":[1],\"outcome\":\"newly_added\",\"later\":{\"a\":null}}",
      )
    },
    (path, _) => {
      let answer = call_json(bridge_env(path), "create_thread", {})
      assert_eq(
        answer, "{\"result\":[1],\"outcome\":\"newly_added\",\"later\":{\"a\":null}}",
      )
    },
  )
}

///|
async test "a call sent without an answer in time is unknown" {
  serial(() => {
    with_bridge("call-6", _ => None, (path, lines) => {
      let answer = call_json(
        bridge_env(path),
        "create_thread",
        {},
        timeout_ms=50,
      )
      assert_eq(
        answer, "{\"outcome\":\"unknown\",\"error\":\"no answer: ETIMEDOUT\"}",
      )
      assert_eq(lines.length(), 1)
    })
  })
}

///|
async test "an answer without an outcome is unknown" {
  for reply in ["{\"version\":1}", "{\"outcome\":3}", "[]", "nope", ""] {
    with_bridge("call-7", _ => Some(reply), (path, _) => {
      let answer = call_json(bridge_env(path), "create_thread", {})
      assert_eq(
        answer, "{\"outcome\":\"unknown\",\"error\":\"no answer: answer without outcome\"}",
      )
    })
  }
}

///|
async test "a bridge that hangs up on the call leaves it unknown" {
  with_server("call-8", stream => ignore(read_request(stream)), path => {
    let answer = call_json(bridge_env(path), "create_thread", {})
    assert_eq(
      answer, "{\"outcome\":\"unknown\",\"error\":\"no answer: answer without outcome\"}",
    )
  })
}

///|
async test "a socket that cannot be reached leaves the call unsent, with a hint" {
  let missing = call_json(
    env_of([("HARNEXUS_CALL_SOCKET", "/nonexistent/call.sock")]),
    "create_thread",
    {},
  )
  assert_true(
    missing.contains(
      "\"error\":\"/nonexistent/call.sock: ENOENT; no bridge has opened the socket; open the app with HARNEXUS_CALL_SOCKET=on",
    ),
  )
  assert_true(missing.has_prefix("{\"outcome\":\"not_sent\""))
  let path = socket_path("call-9")
  @testkit.close_fd(@testkit.listen(path))
  defer @testkit.remove_file(path)
  let refused = call_json(env_of([("HARNEXUS_CALL_SOCKET", path)]), "x", {})
  assert_true(
    refused.contains("\{path}: ECONNREFUSED; a bridge that has exited"),
  )
}

///|
async test "a socket turned off or set wrongly leaves the call unsent" {
  inspect(
    call_json(env_of([("HARNEXUS_CALL_SOCKET", "off")]), "x", {}),
    content="{\"outcome\":\"not_sent\",\"error\":\"the call socket is off (HARNEXUS_CALL_SOCKET=off)\"}",
  )
  inspect(
    call_json(env_of([("HARNEXUS_CALL_SOCKET", "call.sock")]), "x", {}),
    content="{\"outcome\":\"not_sent\",\"error\":\"HARNEXUS_CALL_SOCKET must be on, off or an absolute path\"}",
  )
  inspect(
    call_json(
      env_of([("HOME", "/h"), ("HARNEXUS_STATE_PATH", "state.json")]),
      "x",
      {},
    ),
    content="{\"outcome\":\"not_sent\",\"error\":\"HARNEXUS_STATE_PATH must be an absolute path\"}",
  )
}

///|
test "the socket hint names the cause" {
  inspect(
    socket_hint(Some("EPERM")),
    content="the sandbox blocked the connection; run outside the sandbox",
  )
  inspect(
    socket_hint(Some("EACCES")),
    content="the sandbox blocked the connection; run outside the sandbox",
  )
  assert_true(
    socket_hint(None).has_prefix("open the app with HARNEXUS_CALL_SOCKET=on"),
  )
  assert_true(socket_hint(Some("EOTHER")).has_prefix("open the app with"))
}
