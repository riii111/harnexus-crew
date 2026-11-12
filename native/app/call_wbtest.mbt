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
/// Answers a capabilities query with the operations, and every other line with `answer`.
fn offering(
  operations : Array[String],
  answer : String?,
) -> (String) -> String? {
  line => {
    if line.contains("\"query\":\"capabilities\"") {
      let listed = operations.map(name => Json::string(name))
      Some(
        json_text(
          Json::object({
            "version": Json::number(1.0),
            "outcome": Json::string("done"),
            "operations": Json::array(listed),
          }),
        ),
      )
    } else {
      answer
    }
  }
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
async test "asks for protocol 1, then sends the call with it and answers without the version" {
  with_bridge(
    "call-1",
    offering(
      ["name_thread"],
      Some("{\"version\":1,\"outcome\":\"done\",\"result\":{}}"),
    ),
    (path, lines) => {
      let answer = call_json(bridge_env(path), "name_thread", {
        "name": Json::string("Impl TR1"),
      })
      assert_eq(answer, "{\"outcome\":\"done\",\"result\":{}}")
      assert_eq(lines.length(), 2)
      assert_eq(lines[0], "{\"version\":1,\"query\":\"capabilities\"}")
      assert_eq(
        lines[1],
        "{\"version\":1,\"threadId\":\"w1\",\"tool\":\"name_thread\",\"arguments\":{\"name\":\"Impl TR1\"}}",
      )
    },
  )
}

///|
async test "a bridge's answer keeps every field and the order it was written in" {
  with_bridge(
    "call-2",
    offering(
      ["create_thread"],
      Some(
        "{\"version\":1,\"result\":[1],\"outcome\":\"newly_added\",\"later\":{\"a\":null}}",
      ),
    ),
    (path, _) => {
      let answer = call_json(bridge_env(path), "create_thread", {})
      assert_eq(
        answer, "{\"result\":[1],\"outcome\":\"newly_added\",\"later\":{\"a\":null}}",
      )
    },
  )
}

///|
async test "an older bridge's invalid answer is unsupported and gets nothing more" {
  with_bridge(
    "call-3",
    _ => {
      Some(
        "{\"outcome\":\"invalid\",\"message\":\"expected {threadId,tool,arguments}\"}",
      )
    },
    (path, lines) => {
      let answer = call_json(bridge_env(path), "create_thread", {})
      assert_eq(
        answer, "{\"outcome\":\"unsupported\",\"error\":\"the bridge does not offer call protocol 1; update harnexus and restart the app\"}",
      )
      assert_eq(lines.length(), 1)
    },
  )
}

///|
async test "a capabilities answer of another version or shape is unsupported" {
  for
    reply in [
      "{\"version\":2,\"outcome\":\"done\",\"operations\":[\"create_thread\"]}",
      "{\"version\":1,\"outcome\":\"rejected\",\"operations\":[\"create_thread\"]}",
      "{\"version\":1,\"outcome\":\"done\",\"operations\":\"create_thread\"}", "{\"version\":\"1\",\"outcome\":\"done\",\"operations\":[]}",
      "not json", "",
    ] {
    with_bridge("call-4", _ => Some(reply), (path, lines) => {
      let answer = parse(call_json(bridge_env(path), "create_thread", {}))
      assert_true(json_text(answer).contains("\"outcome\":\"unsupported\""))
      assert_eq(lines.length(), 1)
    })
  }
}

///|
async test "a tool the bridge does not offer is unsupported and sends nothing" {
  with_bridge("call-5", offering(["create_thread"], None), (path, lines) => {
    let answer = call_json(bridge_env(path), "cloud_open", {})
    assert_eq(
      answer, "{\"outcome\":\"unsupported\",\"error\":\"the bridge does not offer cloud_open\"}",
    )
    assert_eq(lines.length(), 1)
  })
}

///|
async test "a call sent without an answer in time is unknown" {
  serial(() => {
    with_bridge("call-6", offering(["create_thread"], None), (path, lines) => {
      let answer = call_json(
        bridge_env(path),
        "create_thread",
        {},
        timeout_ms=50,
      )
      assert_eq(
        answer, "{\"outcome\":\"unknown\",\"error\":\"no answer: ETIMEDOUT\"}",
      )
      assert_eq(lines.length(), 2)
    })
  })
}

///|
async test "an answer without an outcome is unknown" {
  for reply in ["{\"version\":1}", "{\"outcome\":3}", "[]", "nope", ""] {
    with_bridge("call-7", offering(["create_thread"], Some(reply)), (path, _) => {
      let answer = call_json(bridge_env(path), "create_thread", {})
      assert_eq(
        answer, "{\"outcome\":\"unknown\",\"error\":\"no answer: answer without outcome\"}",
      )
    })
  }
}

///|
async test "a bridge that hangs up on the call leaves it unknown" {
  let calls = Ref(0)
  with_server(
    "call-8",
    stream => {
      let line = read_request(stream).unwrap_or("")
      calls.val += 1
      if line.contains("\"query\":\"capabilities\"") {
        stream.write(
          @utf8.encode(
            "{\"version\":1,\"outcome\":\"done\",\"operations\":[\"create_thread\"]}\n",
          ),
        )
      }
    },
    path => {
      let answer = call_json(bridge_env(path), "create_thread", {})
      assert_eq(
        answer, "{\"outcome\":\"unknown\",\"error\":\"no answer: answer without outcome\"}",
      )
    },
  )
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
