///|
let gate : @async.Mutex = @async.Mutex()

///|
/// The test driver runs up to ten tests at once on one thread.
/// Tests that count descriptors or time a deadline run one at a time so another test's sockets and sleeps do not show up in them.
async fn serial(body : async () -> Unit) -> Unit {
  gate.acquire()
  defer gate.release()
  body()
}

///|
/// The real connect, which also records the descriptor the exchange opened so a test can check it is closed afterwards.
fn tracked_connect(path : String, opened : Ref[Int32]) -> (Int32) -> Int32 {
  let target = path_bytes(path)
  fd => {
    opened.val = fd
    connect_once(fd, target)
  }
}

///|
fn socket_path(name : String) -> String {
  "/tmp/hxc-\{@testkit.pid()}-\{name}.sock"
}

///|
/// A server socket that accepts, removed with the test.
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
/// Reads the request line, as the bridge does.
async fn read_request(stream : @raw_fd.RawFdStream) -> String {
  let line = stream.read_until(b"\n") catch { _ => None }
  match line {
    Some(bytes) => @utf8.decode_lossy(bytes)
    None => ""
  }
}

///|
async fn answer(stream : @raw_fd.RawFdStream) -> Unit {
  let line = read_request(stream)
  stream.write(
    @utf8.encode(
      "{\"outcome\":\"done\",\"echoed\":\{Json::string(line).stringify()},\"text\":\"あい🌙\"}\n",
    ),
  )
}

///|
async fn silent(stream : @raw_fd.RawFdStream) -> Unit {
  ignore(read_request(stream))
  @async.sleep(60000)
}

///|
/// Answers in parts, five times 300 ms apart, so the whole answer arrives later than a one second deadline.
async fn drip(stream : @raw_fd.RawFdStream) -> Unit {
  ignore(read_request(stream))
  for i in 0..<5 {
    @async.sleep(300)
    stream.write(@utf8.encode("part\{i};"))
  }
  stream.write(@utf8.encode("\n"))
}

///|
/// Accepts and never reads, so a large request fills the socket buffer and the client's write has to wait.
async fn noread(_stream : @raw_fd.RawFdStream) -> Unit {
  @async.sleep(60000)
}

///|
fn describe_failure(error : @boundary.LineExchangeFailed) -> String {
  let @boundary.LineExchangeFailed(code~, connected~, ..) = error
  "\{if connected { "unknown" } else { "not_sent" }} \{code.unwrap_or("none")}"
}

///|
/// What an exchange came to: its answer, or whether the line was sent and the code of the failure.
async fn outcome_of(
  path : String,
  line : String,
  timeout_ms : Int32,
  connect? : (Int32) -> Int32,
) -> String {
  try {
    let reply = match connect {
      Some(attempt) => exchange_with(path, line, timeout_ms, attempt)
      None => exchange_line(path, line, timeout_ms)
    }
    "done \{Json::string(reply).stringify()}"
  } catch {
    error => describe_failure(error)
  }
}

///|
async fn[T] timed(work : async () -> T) -> (T, Int32) {
  let started = @async.now()
  let value = work()
  (value, (@async.now() - started).to_int())
}

///|
fn assert_between(value : Int32, low : Int32, high : Int32) -> Unit raise {
  if value < low || value > high {
    fail("\{value} is outside \{low}..\{high}")
  }
}

///|
async test "S1 a round trip returns the answer without its newline" {
  serial(() => {
    with_server("s1", answer, path => {
      let before = @testkit.open_fds()
      let reply = exchange_line(path, "{\"x\":1}", 1000)
      assert_eq(
        reply, "{\"outcome\":\"done\",\"echoed\":\"{\\\"x\\\":1}\",\"text\":\"あい🌙\"}",
      )
      assert_eq(@testkit.open_fds(), before)
    })
  })
}

///|
async test "S2 a missing socket is not sent and says ENOENT" {
  serial(() => {
    let before = @testkit.open_fds()
    let result = outcome_of(socket_path("missing"), "{\"x\":1}", 1000)
    assert_eq(result, "not_sent ENOENT")
    assert_eq(@testkit.open_fds(), before)
  })
}

///|
async test "S3 a server that never answers leaves the line unknown at the deadline" {
  serial(() => {
    with_server("s3", silent, path => {
      let opened = Ref(-1)
      let (result, elapsed) = timed(() => {
        outcome_of(
          path,
          "{\"x\":1}",
          1000,
          connect=tracked_connect(path, opened),
        )
      })
      assert_eq(result, "unknown ETIMEDOUT")
      assert_between(elapsed, 800, 1600)
      assert_true(opened.val >= 0 && !@testkit.fd_open(opened.val))
    })
  })
}

///|
async test "S4 a socket file with no server behind it is refused and not sent" {
  serial(() => {
    let path = socket_path("s4")
    @testkit.close_fd(@testkit.listen(path))
    defer @testkit.remove_file(path)
    let result = outcome_of(path, "{\"x\":1}", 1000)
    assert_eq(result, "not_sent ECONNREFUSED")
  })
}

///|
async test "S5 an empty line only probes: the server sees a connection and no bytes" {
  serial(() => {
    let seen = Ref("not called")
    with_server("s5", stream => seen.val = read_request(stream), path => {
      assert_eq(exchange_line(path, "", 1000), "")
      @async.sleep(100)
    })
    assert_eq(seen.val, "")
  })
}

///|
async test "C1 real full listen queue: macOS refuses at once, Linux holds the connect until the deadline" {
  serial(() => {
    let path = socket_path("c1")
    let listener = @testkit.listen(path, backlog=1)
    // Nothing accepts, so connections held open fill the queue.
    let held : Array[Int32] = []
    defer {
      for fd in held {
        @testkit.close_fd(fd)
      }
      @testkit.close_fd(listener)
      @testkit.remove_file(path)
    }
    for _ in 0..<64 {
      let fd = @testkit.connect_and_hold(path) catch { _ => -1 }
      if fd < 0 {
        break
      }
      held.push(fd)
    }
    assert_true(held.length() < 64)
    let (result, elapsed) = timed(() => outcome_of(path, "{\"x\":1}", 1000))
    match @sys.platform() {
      Darwin => {
        assert_eq(result, "not_sent ECONNREFUSED")
        assert_between(elapsed, 0, 500)
      }
      _ => {
        assert_eq(result, "not_sent ETIMEDOUT")
        assert_between(elapsed, 800, 1600)
      }
    }
  })
}

///|
async test "C2 injected: a connect that keeps answering EAGAIN ends at the deadline unsent, while other tasks run" {
  serial(() => {
    let ticks = Ref(0)
    let outcome = Ref("")
    let elapsed = Ref(0)
    let before = @testkit.open_fds()
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        while true {
          @async.sleep(20)
          ticks.val += 1
        }
      })
      let (result, ms) = timed(() => {
        outcome_of(socket_path("c2"), "{\"x\":1}", 1000, connect=_ => {
          @testkit.eagain()
        })
      })
      outcome.val = result
      elapsed.val = ms
    })
    assert_eq(outcome.val, "not_sent ETIMEDOUT")
    assert_between(elapsed.val, 800, 1600)
    assert_true(ticks.val >= 30)
    assert_eq(@testkit.open_fds(), before)
  })
}

///|
async test "C3 injected: a connect that answers EAGAIN 20 times then succeeds is made once" {
  serial(() => {
    with_server("c3", answer, path => {
      let attempts = Ref(0)
      let target = path_bytes(path)
      let reply = exchange_with(path, "{\"x\":1}", 1000, fd => {
        attempts.val += 1
        if attempts.val <= 20 {
          @testkit.eagain()
        } else {
          connect_once(fd, target)
        }
      })
      assert_true(reply.contains("\"outcome\":\"done\""))
      assert_eq(attempts.val, 21)
    })
  })
}

///|
async test "C4 injected: connect, write and read share one deadline" {
  serial(() => {
    with_server("c4", drip, path => {
      let attempts = Ref(0)
      let connected_at = Ref(-1)
      let started = @async.now()
      let target = path_bytes(path)
      let (result, elapsed) = timed(() => {
        outcome_of(path, "{\"x\":1}", 1000, connect=fd => {
          attempts.val += 1
          if attempts.val <= 50 {
            return @testkit.eagain()
          }
          let errno = connect_once(fd, target)
          if errno == 0 {
            connected_at.val = (@async.now() - started).to_int()
          }
          errno
        })
      })
      assert_eq(result, "unknown ETIMEDOUT")
      assert_between(elapsed, 800, 1600)
      assert_between(connected_at.val, 400, 800)
    })
  })
}

///|
async test "C5 a slow answer past the deadline is unknown" {
  serial(() => {
    with_server("c5", drip, path => {
      let (result, elapsed) = timed(() => outcome_of(path, "{\"x\":1}", 1000))
      assert_eq(result, "unknown ETIMEDOUT")
      assert_between(elapsed, 800, 1600)
    })
  })
}

///|
async test "C6 a peer that never reads leaves a large request unknown at the deadline" {
  serial(() => {
    with_server("c6", noread, path => {
      let opened = Ref(-1)
      let line = String::make(4 * 1024 * 1024, 'x')
      let (result, elapsed) = timed(() => {
        outcome_of(path, line, 1000, connect=tracked_connect(path, opened))
      })
      assert_eq(result, "unknown ETIMEDOUT")
      assert_between(elapsed, 800, 1600)
      assert_true(opened.val >= 0 && !@testkit.fd_open(opened.val))
    })
  })
}

///|
async test "cancelling an exchange closes its descriptor" {
  serial(() => {
    with_server("cancel", silent, path => {
      let opened = Ref(-1)
      let connect = tracked_connect(path, opened)
      let finished = @async.with_timeout_opt(100, () => {
        exchange_with(path, "{\"x\":1}", 30000, connect)
      })
      assert_true(finished is None)
      assert_true(opened.val >= 0 && !@testkit.fd_open(opened.val))
    })
  })
}

///|
async test "a character split across two writes is read whole and bad bytes become U+FFFD" {
  serial(() => {
    with_server(
      "utf8",
      stream => {
        ignore(read_request(stream))
        stream.write(b"\xe3\x81")
        @async.sleep(100)
        stream.write(b"\x82 \xff\xe3\x41\n")
      },
      path => assert_eq(exchange_line(path, "x", 1000), "あ \u{fffd}\u{fffd}A"),
    )
  })
}

///|
async test "a peer that closes without answering is an empty answer" {
  serial(() => {
    with_server("closes", stream => ignore(read_request(stream)), path => {
      assert_eq(exchange_line(path, "x", 1000), "")
    })
  })
}

///|
async test "trailing white space is trimmed the way JavaScript trims" {
  serial(() => {
    with_server(
      "trim",
      stream => {
        ignore(read_request(stream))
        stream.write(@utf8.encode("{\"a\":1}\u{a0}\u{3000} \r\n\u{2028}\t"))
      },
      path => assert_eq(exchange_line(path, "x", 1000), "{\"a\":1}"),
    )
    inspect(trim_end("a\u{200b}"), content="a\u{200b}")
    inspect(trim_end("a\u{180e}"), content="a\u{180e}")
    inspect(trim_end("a\u{85}"), content="a\u{85}")
    inspect(trim_end("a\u{feff}\u{b}\u{c}"), content="a")
    inspect(trim_end("  "), content="")
    inspect(trim_end(" a b "), content=" a b")
  })
}

///|
async test "a path that cannot be a socket address is refused before anything is sent" {
  serial(() => {
    let long = String::make(300, 'a')
    assert_eq(outcome_of("/tmp/\{long}", "x", 1000), "not_sent ENAMETOOLONG")
    assert_eq(
      outcome_of("/tmp/a\u{0}b", "x", 1000),
      "not_sent ERR_INVALID_ARG_VALUE",
    )
  })
}

///|
async test "the failure keeps the path and the message callers show" {
  serial(() => {
    let path = socket_path("message")
    try exchange_line(path, "x", 1000) |> ignore catch {
      @boundary.LineExchangeFailed(path=failed_path, message~, ..) => {
        assert_eq(failed_path, path)
        assert_eq(message, "cannot reach \{path}")
      }
    } noraise {
      _ => fail("expected a failure")
    }
  })
}
