///|
/// A test driver for the store: `test/test_store.py` starts several of these at once to race them on one directory.
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
    "read" => read_text(args)
    "read-regular" => read_regular(args)
    "save-json" => save_record(args)
    _ => object([("error", Json::string("unknown command \{command}"))])
  }
  emit(line)
}

///|
/// Takes the lock at the shared start time, holds it for the given milliseconds and releases it.
/// args[2]: Lock.
/// args[3]: Holder.
/// args[4]: Hold time in milliseconds.
/// args[5]: Start time.
async fn acquire_and_hold(args : Array[String]) -> Json {
  wait_until(number_arg(args, 5))
  try {
    let token = @storage.acquire(arg(args, 2), arg(args, 3))
    let from = now_millis_json()
    @async.sleep(number_arg(args, 4).to_int())
    let to = now_millis_json()
    @storage.release(arg(args, 2), token)
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
    let token = @storage.acquire(arg(args, 2), arg(args, 3))
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
  let pid = Json::number(@testkit.pid().to_double())
  try {
    let made = @storage.write_exclusive(
      marker,
      object([("pid", pid)]).stringify(),
    )
    object([("ok", Json::boolean(made))])
  } catch {
    failed => refused(failed.user_message())
  }
}

///|
/// The content is `size` copies of one string, built here because an argument can hold only about 128 KiB on Linux.
/// args[2]: Path.
/// args[3]: String.
/// args[4]: Size.
/// args[5]: Start time.
async fn create_exclusive(args : Array[String]) -> Json {
  let content = arg(args, 3).repeat(number_arg(args, 4).to_int())
  wait_until(number_arg(args, 5))
  try {
    let created = @storage.write_exclusive(arg(args, 2), content)
    object([("created", Json::boolean(created))])
  } catch {
    failed => refused(failed.user_message())
  }
}

///|
/// Replaces a file again and again with `size` copies of one character, so that a reader can tell a whole write from a torn one.
/// args[2]: Path.
/// args[3]: Character.
/// args[4]: Size.
/// args[5]: Run time in milliseconds.
async fn write_in_loop(args : Array[String]) -> Json {
  let content = arg(args, 3).repeat(number_arg(args, 4).to_int())
  let until = now_millis() + number_arg(args, 5)
  let mut writes = 0
  try {
    while now_millis() < until {
      @storage.write_atomic(arg(args, 2), content)
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
/// args[2]: Lock directory.
/// args[3]: Lock name.
/// args[4]: Counter file.
/// args[5]: Increments.
/// args[6]: Start time.
/// args[7]: Wait time in milliseconds.
async fn count_under_lock(args : Array[String]) -> Json {
  wait_until(number_arg(args, 6))
  let counter = arg(args, 4)
  try {
    for _ in 0..<number_arg(args, 5).to_int() {
      @storage.with_lock(
        arg(args, 2),
        arg(args, 3),
        () => increment_counter(counter),
        wait_ms=number_arg(args, 7).to_int(),
      )
    }
    object([("ok", Json::boolean(true))])
  } catch {
    failed => refused(failed.message())
  }
}

///|
fn increment_counter(counter : String) -> Unit raise @failure.TaskFailed {
  try {
    let current = @storage.read_text_if_exists(counter)
      .map(number_of)
      .unwrap_or(0L)
    // Reading and writing are far enough apart for an unguarded run to be overtaken.
    @storage.write_atomic(counter, (current + 1L).to_string())
  } catch {
    failed => @failure.fail(failed.user_message())
  }
}

///|
fn read_text(args : Array[String]) -> Json {
  try {
    match @storage.read_text_if_exists(arg(args, 2)) {
      Some(text) => object([("text", Json::string(text))])
      None => object([("text", Json::null())])
    }
  } catch {
    failed => refused(failed.user_message())
  }
}

///|
fn read_regular(args : Array[String]) -> Json {
  object([("text", Json::string(@storage.read_regular_text(arg(args, 2))))]) catch {
    failed => refused(failed.user_message())
  }
}

///|
/// args[2]: Path.
/// args[3]: JSON text.
/// args[4]: "exclusive" or "replace".
fn save_record(args : Array[String]) -> Json {
  let data = @jsonio.parse(arg(args, 3)) catch {
    @jsonio.JsonError(message) => return refused(message)
  }
  try {
    @storage.save_json(
      arg(args, 2),
      data,
      exclusive=arg(args, 4) == "exclusive",
    )
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
fn now_millis() -> Int64 {
  @env.now().reinterpret_as_int64()
}

///|
fn now_millis_json() -> Json {
  Json::number(now_millis().to_double())
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
  @sys.write_text(1, line.stringify() + "\n") catch {
    _ => abort("cannot write")
  }
}

///|
/// Waits for a shared start time so that processes started one by one begin together.
async fn wait_until(at : Int64) -> Unit {
  while now_millis() < at {
    @async.sleep(1)
  }
}
