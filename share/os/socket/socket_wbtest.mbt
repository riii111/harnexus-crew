///|
async test "S1 a round trip returns the answer without its newline" {
  @testkit.serial(() => {
    with_server("s1", answer, path => {
      let reply = exchange_line(path, "{\"x\":1}", 1000)

      assert_eq(reply, echoed_reply)
    })
  })
}

///|
async test "a round trip leaves no descriptor open" {
  @testkit.serial(() => {
    with_server("s1-fds", answer, path => {
      let before = @testkit.open_fds()

      let reply = exchange_line(path, "{\"x\":1}", 1000)

      assert_eq(reply, echoed_reply)
      assert_eq(@testkit.open_fds(), before)
    })
  })
}

///|
async test "S2 a missing socket is reported as not sent with ENOENT" {
  @testkit.serial(() => {
    let result = describe_exchange(socket_path("missing"), "{\"x\":1}", 1000)

    assert_eq(result, "not_sent ENOENT")
  })
}

///|
async test "a missing socket leaves no descriptor open" {
  @testkit.serial(() => {
    let before = @testkit.open_fds()

    let result = describe_exchange(
      socket_path("missing-fds"),
      "{\"x\":1}",
      1000,
    )

    assert_eq(result, "not_sent ENOENT")
    assert_eq(@testkit.open_fds(), before)
  })
}

///|
async test "S3 a server that never answers leaves the line unknown at the deadline" {
  @testkit.serial(() => {
    with_server("s3", stay_silent, path => {
      let (result, elapsed) = @testkit.timed(() => {
        describe_exchange(path, "{\"x\":1}", 1000)
      })

      assert_eq(result, "unknown ETIMEDOUT")
      @testkit.assert_between(elapsed, 800, 1600)
    })
  })
}

///|
async test "a server that never answers leaves no descriptor open on the client" {
  @testkit.serial(() => {
    with_server("s3-fds", stay_silent, path => {
      let opened = Ref(-1)

      let result = describe_exchange(
        path,
        "{\"x\":1}",
        1000,
        connect=tracked_connect(path, opened),
      )

      assert_eq(result, "unknown ETIMEDOUT")
      assert_closed(opened.val)
    })
  })
}

///|
async test "S4 a socket file with no server behind it is refused and not sent" {
  @testkit.serial(() => {
    let path = socket_path("s4")
    @testkit.close_fd(@testkit.listen(path))
    defer @testkit.remove_file(path)
    let result = describe_exchange(path, "{\"x\":1}", 1000)

    assert_eq(result, "not_sent ECONNREFUSED")
  })
}

///|
async test "S5 an empty line only probes: the server sees a connection and no bytes" {
  @testkit.serial(() => {
    let seen = Ref(-1)

    // Everything the server receives until the client closes, so a stray newline would show.
    with_server("s5", stream => seen.val = stream.read_all().length(), path => {
      assert_eq(exchange_line(path, "", 1000), "")
      @async.sleep(100)
    })

    assert_eq(seen.val, 0)
  })
}

///|
async test "C1 real full listen queue: macOS refuses at once, Linux holds the connect until the deadline" {
  @testkit.serial(() => {
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

    @testkit.assert_between(held.length(), 1, 63)

    let (result, elapsed) = @testkit.timed(() => {
      describe_exchange(path, "{\"x\":1}", 1000)
    })

    if @testkit.is_macos() {
      assert_eq(result, "not_sent ECONNREFUSED")
      @testkit.assert_between(elapsed, 0, 500)
    } else {
      assert_eq(result, "not_sent ETIMEDOUT")
      @testkit.assert_between(elapsed, 800, 1600)
    }
  })
}

///|
async test "C2 injected: a connect that keeps answering EAGAIN ends at the deadline unsent" {
  @testkit.serial(() => {
    let (result, elapsed, _, _) = eagain_exchange()

    assert_eq(result, "not_sent ETIMEDOUT")
    @testkit.assert_between(elapsed, 800, 1600)
  })
}

///|
async test "C2 injected: a connect that keeps answering EAGAIN lets other tasks run" {
  @testkit.serial(() => {
    let (result, _, ticks, _) = eagain_exchange()

    assert_eq(result, "not_sent ETIMEDOUT")
    @testkit.assert_between(ticks, 30, 200)
  })
}

///|
async test "C2 injected: a connect that keeps answering EAGAIN leaves no descriptor open" {
  @testkit.serial(() => {
    let (result, _, _, leaked) = eagain_exchange()

    assert_eq(result, "not_sent ETIMEDOUT")
    assert_eq(leaked, 0)
  })
}

///|
async test "C3 injected: a connect that answers EAGAIN 20 times then succeeds is made once" {
  @testkit.serial(() => {
    with_server("c3", answer, path => {
      let attempts = Ref(0)
      let target = @sys.c_string(path).unwrap()

      let reply = exchange_with(path, "{\"x\":1}", 1000, fd => {
        attempts.val += 1

        if attempts.val <= 20 {
          @testkit.eagain()
        } else {
          connect_once(fd, target)
        }
      })

      assert_eq(reply, echoed_reply)
      assert_eq(attempts.val, 21)
    })
  })
}

///|
async test "C4 injected: connect, write and read share one deadline" {
  @testkit.serial(() => {
    with_server("c4", drip_answer, path => {
      let attempts = Ref(0)
      let connected_at = Ref(-1)
      let started = @async.now()
      let target = @sys.c_string(path).unwrap()

      let (result, elapsed) = @testkit.timed(() => {
        describe_exchange(path, "{\"x\":1}", 1000, connect=fd => {
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
      @testkit.assert_between(elapsed, 800, 1600)
      @testkit.assert_between(connected_at.val, 400, 800)
    })
  })
}

///|
async test "C5 a slow answer past the deadline is unknown" {
  @testkit.serial(() => {
    with_server("c5", drip_answer, path => {
      let (result, elapsed) = @testkit.timed(() => {
        describe_exchange(path, "{\"x\":1}", 1000)
      })

      assert_eq(result, "unknown ETIMEDOUT")
      @testkit.assert_between(elapsed, 800, 1600)
    })
  })
}

///|
async test "C6 a peer that never reads leaves a large request unknown at the deadline" {
  @testkit.serial(() => {
    with_server("c6", never_read, path => {
      let line = String::make(4 * 1024 * 1024, 'x')

      let (result, elapsed) = @testkit.timed(() => {
        describe_exchange(path, line, 1000)
      })

      assert_eq(result, "unknown ETIMEDOUT")
      @testkit.assert_between(elapsed, 800, 1600)
    })
  })
}

///|
async test "a peer that never reads leaves no descriptor open on the client" {
  @testkit.serial(() => {
    with_server("c6-fds", never_read, path => {
      let opened = Ref(-1)
      let line = String::make(4 * 1024 * 1024, 'x')

      let result = describe_exchange(
        path,
        line,
        1000,
        connect=tracked_connect(path, opened),
      )

      assert_eq(result, "unknown ETIMEDOUT")
      assert_closed(opened.val)
    })
  })
}

///|
async test "cancelling an exchange closes its descriptor" {
  @testkit.serial(() => {
    with_server("cancel", stay_silent, path => {
      let opened = Ref(-1)
      let connect = tracked_connect(path, opened)

      let finished = @async.with_timeout_opt(100, () => {
        exchange_with(path, "{\"x\":1}", 30000, connect)
      })

      assert_eq(finished, None)
      assert_closed(opened.val)
    })
  })
}

///|
async test "a character split across two writes is read whole" {
  @testkit.serial(() => {
    with_server(
      "utf8-split",
      stream => {
        ignore(read_request(stream))
        stream.write(b"\xe3\x81")
        @async.sleep(100)
        stream.write(b"\x82\n")
      },
      path => assert_eq(exchange_line(path, "x", 1000), "あ"),
    )
  })
}

///|
async test "bad bytes in an answer become U+FFFD" {
  @testkit.serial(() => {
    with_server(
      "utf8-bad",
      stream => {
        ignore(read_request(stream))
        stream.write(b"\xff\xe3\x41\n")
      },
      path => assert_eq(exchange_line(path, "x", 1000), "\u{fffd}\u{fffd}A"),
    )
  })
}

///|
async test "a peer that closes without answering is an empty answer" {
  @testkit.serial(() => {
    with_server("closes", stream => ignore(read_request(stream)), path => {
      assert_eq(exchange_line(path, "x", 1000), "")
    })
  })
}

///|
async test "trailing white space of an answer is trimmed the way JavaScript trims" {
  @testkit.serial(() => {
    with_server(
      "trim",
      stream => {
        ignore(read_request(stream))
        stream.write(@utf8.encode("{\"a\":1}\u{a0}\u{3000} \r\n\u{2028}\t"))
      },
      path => assert_eq(exchange_line(path, "x", 1000), "{\"a\":1}"),
    )
  })
}

///|
async test "a path too long for a socket address is refused before anything is sent" {
  @testkit.serial(() => {
    let long = String::make(300, 'a')

    let result = describe_exchange("\{@testkit.temp_base()}/\{long}", "x", 1000)

    assert_eq(result, "not_sent ENAMETOOLONG")
  })
}

///|
async test "a path with a NUL byte is refused before anything is sent" {
  @testkit.serial(() => {
    let result = describe_exchange("\{@testkit.temp_base()}/a\u{0}b", "x", 1000)

    assert_eq(result, "not_sent ERR_INVALID_ARG_VALUE")
  })
}

///|
async test "the failure keeps the path of the exchange" {
  @testkit.serial(() => {
    let path = socket_path("failure-path")

    let (failed_path, _) = exchange_failure(path)

    assert_eq(failed_path, path)
  })
}

///|
async test "the failure carries the message callers show" {
  @testkit.serial(() => {
    let path = socket_path("failure-message")

    let (_, message) = exchange_failure(path)

    assert_eq(message, "cannot reach \{path}")
  })
}

///|
/// The real connect, which also records the descriptor the exchange opened so a test can check it is closed afterwards.
fn tracked_connect(path : String, opened : Ref[Int32]) -> (Int32) -> Int32 {
  let target = @sys.c_string(path).unwrap()

  fd => {
    opened.val = fd
    connect_once(fd, target)
  }
}

///|
fn socket_path(name : String) -> String {
  "\{@testkit.temp_base()}/hxc-\{@testkit.pid()}-\{name}.sock"
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
/// None when the peer closed before sending a line, which differs from a line that is empty.
async fn read_request(stream : @raw_fd.RawFdStream) -> String? {
  let line = stream.read_until(b"\n") catch { _ => None }
  line.map(bytes => @utf8.decode_lossy(bytes))
}

///|
async fn answer(stream : @raw_fd.RawFdStream) -> Unit {
  let line = read_request(stream).unwrap_or("")
  stream.write(
    @utf8.encode(
      "{\"outcome\":\"done\",\"echoed\":\{Json::string(line).stringify()},\"text\":\"あい🌙\"}\n",
    ),
  )
}

///|
async fn stay_silent(stream : @raw_fd.RawFdStream) -> Unit {
  ignore(read_request(stream))
  @async.sleep(60000)
}

///|
/// Answers in parts spaced so the whole answer arrives later than a one second deadline.
async fn drip_answer(stream : @raw_fd.RawFdStream) -> Unit {
  ignore(read_request(stream))

  for i in 0..<5 {
    @async.sleep(300)
    stream.write(@utf8.encode("part\{i};"))
  }

  stream.write(@utf8.encode("\n"))
}

///|
/// Accepts and never reads, so a large request fills the socket buffer and the client's write has to wait.
async fn never_read(_stream : @raw_fd.RawFdStream) -> Unit {
  @async.sleep(60000)
}

///|
fn describe_failure(error : @boundary.LineExchangeFailed) -> String {
  let @boundary.LineExchangeFailed(code~, connected~, ..) = error
  "\{if connected { "unknown" } else { "not_sent" }} \{code.unwrap_or("none")}"
}

///|
/// What an exchange came to: its answer, or whether the line was sent and the code of the failure.
async fn describe_exchange(
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
let echoed_reply : String = "{\"outcome\":\"done\",\"echoed\":\"{\\\"x\\\":1}\",\"text\":\"あい🌙\"}"

///|
fn assert_closed(fd : Int32) -> Unit raise {
  assert_true(fd >= 0, msg="no descriptor was opened")
  assert_eq(@testkit.fd_open(fd), false, msg="descriptor \{fd} is still open")
}

///|
async fn eagain_exchange() -> (String, Int32, Int32, Int32) {
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

    let (result, ms) = @testkit.timed(() => {
      describe_exchange(socket_path("c2"), "{\"x\":1}", 1000, connect=_ => {
        @testkit.eagain()
      })
    })

    outcome.val = result
    elapsed.val = ms
  })

  (outcome.val, elapsed.val, ticks.val, @testkit.open_fds() - before)
}

///|
async fn exchange_failure(path : String) -> (String, String) {
  try exchange_line(path, "x", 1000) |> ignore catch {
    @boundary.LineExchangeFailed(path=failed_path, message~, ..) =>
      (failed_path, message)
  } noraise {
    _ => fail("expected a failure")
  }
}
