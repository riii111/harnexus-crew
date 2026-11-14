///|
async test "a call is sent as one protocol 1 line naming the thread, tool and arguments" {
  with_bridge(
    "call-1",
    _ => Some("{\"version\":1,\"outcome\":\"done\",\"result\":{}}"),
    (path, lines) => {
      ignore(
        call_json(bridge_env(path), "name_thread", {
          "name": Json::string("Impl TR1"),
        }),
      )

      assert_eq(lines, [
        "{\"version\":1,\"threadId\":\"w1\",\"tool\":\"name_thread\",\"arguments\":{\"name\":\"Impl TR1\"}}",
      ])
    },
  )
}

///|
async test "a bridge's answer comes back without the protocol version" {
  with_bridge(
    "call-10",
    _ => Some("{\"version\":1,\"outcome\":\"done\",\"result\":{}}"),
    (path, _) => {
      let answer = call_json(bridge_env(path), "name_thread", {
        "name": Json::string("Impl TR1"),
      })

      assert_eq(answer, "{\"outcome\":\"done\",\"result\":{}}")
    },
  )
}

///|
async test "a bridge's answer keeps every field" {
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
        @jsonio.parse(answer),
        @jsonio.parse(
          "{\"result\":[1],\"outcome\":\"newly_added\",\"later\":{\"a\":null}}",
        ),
      )
    },
  )
}

///|
async test "a call sent without an answer in time is unknown" {
  @testkit.serial(() => {
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
        answer,
        "{\"outcome\":\"unknown\",\"error\":\"no answer: answer without outcome\"}",
        msg=reply,
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
async test "a socket path nobody listens on leaves the call unsent, with a hint to open the app" {
  let answer = call_json(
    @app_testkit.env_of([("HARNEXUS_CALL_SOCKET", "/nonexistent/call.sock")]),
    "create_thread",
    {},
  )

  assert_eq(
    answer,
    failed_json(
      "not_sent",
      "/nonexistent/call.sock: ENOENT; no bridge has opened the socket; \{SOCKET_HINT}",
    ),
  )
}

///|
async test "a socket left by an exited bridge leaves the call unsent, with a hint to run again" {
  let path = socket_path("call-9")
  @testkit.close_fd(@testkit.listen(path))
  defer @testkit.remove_file(path)

  let answer = call_json(
    @app_testkit.env_of([("HARNEXUS_CALL_SOCKET", path)]),
    "x",
    {},
  )

  assert_eq(
    answer,
    failed_json(
      "not_sent",
      "\{path}: ECONNREFUSED; a bridge that has exited left the socket; the running bridge takes it over within seconds, so run again, and reopen the app if it persists",
    ),
  )
}

///|
async test "a socket turned off leaves the call unsent" {
  let answer = call_json(
    @app_testkit.env_of([("HARNEXUS_CALL_SOCKET", "off")]),
    "x",
    {},
  )

  assert_eq(
    answer,
    failed_json("not_sent", "the call socket is off (HARNEXUS_CALL_SOCKET=off)"),
  )
}

///|
async test "a socket setting the environment refuses leaves the call unsent with its message" {
  for
    env in [
      @app_testkit.env_of([("HARNEXUS_CALL_SOCKET", "call.sock")]),
      @app_testkit.env_of([
        ("HOME", "/h"),
        ("HARNEXUS_STATE_PATH", "state.json"),
      ]),
    ] {
    let refusal = @app_testkit.failure_of(() => {
      ignore(@environment.resolve_caller_socket(env))
    })

    assert_eq(
      call_json(env, "x", {}),
      failed_json("not_sent", refusal),
      msg=refusal,
    )
  }
}

///|
test "a sandbox refusal gets the sandbox hint" {
  for code in ["EPERM", "EACCES"] {
    assert_eq(
      socket_hint(Some(code)),
      "the sandbox blocked the connection; run outside the sandbox",
      msg=code,
    )
  }
}

///|
test "no error code, or an unknown one, gets the general hint" {
  assert_eq(socket_hint(None), SOCKET_HINT, msg="none")
  assert_eq(socket_hint(Some("EOTHER")), SOCKET_HINT, msg="EOTHER")
}

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
  @app_testkit.env_of([("HARNEXUS_CALL_SOCKET", path), ("HOME", "/nonexistent")])
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
/// A bridge listening on a Unix socket, removed with the test.
/// `handle` runs once for each accepted connection.
async fn with_server(
  name : String,
  handle : async (@raw_fd.RawFdStream) -> Unit,
  body : async (String) -> Unit,
) -> Unit {
  let path = socket_path(name)
  let listener = @testkit.listen(path)
  defer {
    @testkit.close_fd(listener)
    @testkit.remove_file(path)
  }
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      while true {
        match @testkit.accept(listener) {
          Some(fd) =>
            group.spawn_bg(no_wait=true, () => {
              let stream = @raw_fd.RawFdStream(fd)
              defer stream.close()
              handle(stream)
            })
          None => @async.sleep(5)
        }
      }
    })
    body(path)
  })
}

///|
/// The request line, as the bridge reads it; None when the peer closed before sending one.
async fn read_request(stream : @raw_fd.RawFdStream) -> String? {
  let line = stream.read_until(b"\n") catch { _ => None }
  line.map(bytes => @utf8.decode_lossy(bytes))
}

///|
fn socket_path(name : String) -> String {
  "\{@testkit.temp_base()}/hxa-\{@testkit.pid()}-\{name}.sock"
}
