///|
/// A test driver for the store: `test/native/store.test.ts` starts several of these at once to race them on one directory.
/// Each command prints one JSON object and exits; it is not part of the CLI.
async fn main {
  let args = @env.args()
  let command = arg(args, 1)
  let line = match command {
    "acquire" => acquire_and_hold(args)
    "hold" => hold(args)
    "marker-die" => leave_marker(args)
    "exclusive" => create_exclusive(args)
    "atomic-loop" => write_in_loop(args)
    "with-lock" => count_under_lock(args)
    "append" => append_lines(args)
    "read" => read_text(args)
    "read-regular" => read_regular(args)
    "save-json" => save_record(args)
    "state-directory" =>
      object([
        (
          "path",
          Json::string(
            @store.state_directory(arg(args, 2), arg(args, 3), arg(args, 4)),
          ),
        ),
      ])
    _ => object([("error", Json::string("unknown command \{command}"))])
  }
  emit(line)
}

///|
/// Takes the lock at the shared start time, holds it for the given milliseconds and releases it.
/// Arguments: lock, holder, hold milliseconds, start time.
async fn acquire_and_hold(args : Array[String]) -> Json {
  wait_until(number_arg(args, 5))
  try {
    let token = @store.acquire(arg(args, 2), arg(args, 3))
    let from = now_ms()
    @async.sleep(number_arg(args, 4).to_int())
    let to = now_ms()
    @store.release(arg(args, 2), token)
    object([
      ("ok", Json::boolean(true)),
      ("token", Json::string(token)),
      ("from", from),
      ("to", to),
    ])
  } catch {
    failed => refused(failed.message())
  }
}

///|
/// Takes the lock, reports its token, and keeps it until the process is killed.
async fn hold(args : Array[String]) -> Json {
  try {
    let token = @store.acquire(arg(args, 2), arg(args, 3))
    emit(object([("ok", Json::boolean(true)), ("token", Json::string(token))]))
    @async.sleep(600000)
    object([("ok", Json::boolean(true))])
  } catch {
    failed => refused(failed.message())
  }
}

///|
/// Creates the takeover marker of a lock for this process and exits at once, as a run that died while taking over a lock would.
fn leave_marker(args : Array[String]) -> Json {
  let marker = arg(args, 2) + ".reap"
  let pid = Json::number(@store.current_pid().to_double())
  try {
    let made = @store.write_exclusive(
      marker,
      @jsonio.stringify(object([("pid", pid)])),
    )
    object([("ok", Json::boolean(made))])
  } catch {
    failed => refused(failed.user_message())
  }
}

///|
/// Arguments: path, content, start time.
async fn create_exclusive(args : Array[String]) -> Json {
  wait_until(number_arg(args, 4))
  try {
    let created = @store.write_exclusive(arg(args, 2), arg(args, 3))
    object([("created", Json::boolean(created))])
  } catch {
    failed => refused(failed.user_message())
  }
}

///|
/// Replaces a file again and again with `size` copies of one character, so that a reader can tell a whole write from a torn one.
/// Arguments: path, character, size, milliseconds to run.
async fn write_in_loop(args : Array[String]) -> Json {
  let content = arg(args, 3).repeat(number_arg(args, 4).to_int())
  let until = now_number() + number_arg(args, 5)
  let mut writes = 0
  try {
    while now_number() < until {
      @store.write_atomic(arg(args, 2), content)
      writes += 1
      @async.pause()
    }
    object([("writes", Json::number(writes.to_double()))])
  } catch {
    failed => refused(failed.user_message())
  }
}

///|
/// Adds one to a counter file `increments` times, each time under the lock, so a lost update shows as a smaller total.
/// Arguments: lock directory, lock name, counter file, increments, start time, wait milliseconds.
async fn count_under_lock(args : Array[String]) -> Json {
  wait_until(number_arg(args, 6))
  let counter = arg(args, 4)
  try {
    for _ in 0..<number_arg(args, 5).to_int() {
      @store.with_lock(
        arg(args, 2),
        arg(args, 3),
        () => {
          try {
            let current = match @store.read_text_if_exists(counter) {
              Some(text) => number_of(text)
              None => 0L
            }
            // Reading and writing are far enough apart for an unguarded run to be overtaken.
            @store.write_atomic(counter, (current + 1L).to_string())
          } catch {
            failed => @failure.fail(failed.user_message())
          }
        },
        wait_ms=number_arg(args, 7).to_int(),
      )
    }
    object([("ok", Json::boolean(true))])
  } catch {
    failed => refused(failed.message())
  }
}

///|
/// Arguments: path, line, count, start time.
async fn append_lines(args : Array[String]) -> Json {
  wait_until(number_arg(args, 5))
  try {
    for _ in 0..<number_arg(args, 4).to_int() {
      @store.append_line(arg(args, 2), arg(args, 3))
    }
    object([("ok", Json::boolean(true))])
  } catch {
    failed => refused(failed.user_message())
  }
}

///|
fn read_text(args : Array[String]) -> Json {
  try {
    match @store.read_text_if_exists(arg(args, 2)) {
      Some(text) => object([("text", Json::string(text))])
      None => object([("text", Json::null())])
    }
  } catch {
    failed => refused(failed.user_message())
  }
}

///|
fn read_regular(args : Array[String]) -> Json {
  object([("text", Json::string(@store.read_regular_text(arg(args, 2))))]) catch {
    failed => refused(failed.user_message())
  }
}

///|
/// Arguments: path, JSON text, "exclusive" or "replace".
fn save_record(args : Array[String]) -> Json {
  let data = @jsonio.parse(arg(args, 3)) catch {
    @jsonio.JsonError(message) => return refused(message)
  }
  try {
    @store.save_json(arg(args, 2), data, exclusive=arg(args, 4) == "exclusive")
    object([("ok", Json::boolean(true))])
  } catch {
    failed => refused(failed.message())
  }
}

///|
fn arg(args : Array[String], index : Int32) -> String {
  args.get(index).unwrap_or("")
}

///|
/// A non-negative whole number written in decimal.
fn number_of(text : String) -> Int64 {
  let mut value = 0L
  for unit in text.code_units() {
    if unit < '0' || unit > '9' {
      break
    }
    value = value * 10L + (unit - '0').to_int64()
  }
  value
}

///|
fn number_arg(args : Array[String], index : Int32) -> Int64 {
  number_of(arg(args, index))
}

///|
fn now_number() -> Int64 {
  @env.now().reinterpret_as_int64()
}

///|
fn now_ms() -> Json {
  Json::number(now_number().to_double())
}

///|
fn object(members : Array[(String, Json)]) -> Json {
  Json::object(Map::from_array(members))
}

///|
fn refused(message : String) -> Json {
  object([("ok", Json::boolean(false)), ("message", Json::string(message))])
}

///|
fn emit(line : Json) -> Unit {
  @sys.write_text(1, @jsonio.stringify(line) + "\n") catch {
    _ => abort("cannot write")
  }
}

///|
/// Waits for a shared start time so that processes started one by one begin together.
async fn wait_until(at : Int64) -> Unit {
  while now_number() < at {
    @async.sleep(1)
  }
}
