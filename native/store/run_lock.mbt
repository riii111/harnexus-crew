///|
/// Takes the lock at once or fails; the returned token proves it is this run's lock when releasing.
/// A lock whose holder died is taken over, and of several runs doing that only one removes the lock.
pub fn acquire(
  lock : String,
  holder : String,
) -> String raise @failure.TaskFailed {
  let token = new_uuid()
  for _ in 0..<2 {
    let content : Map[String, Json] = Map::from_array([
      ("pid", Json::number(current_pid().to_double())),
      ("token", Json::string(token)),
      ("startedAt", Json::string(now_iso())),
    ])
    let created = io(() => {
      write_exclusive(lock, @jsonio.stringify(Json::object(content)))
    })
    if created {
      return token
    }
    let held = held_by(lock)
    guard held is Some(current) && dead(current) else {
      let pid = match held {
        Some({ "pid": Number(pid, ..), .. }) =>
          " (pid \{@jsonio.stringify(Json::number(pid))})"
        _ => ""
      }
      @failure.fail("another \{holder}\{pid} is using this session")
    }
    if !reap(lock, js_text(current.get("token"))) {
      @failure.fail("another \{holder} is taking over this session")
    }
  }
  @failure.fail("cannot take \{lock}")
}

///|
/// Releases the lock only if it is still the one `token` took, so a lock another run holds now stays.
/// A lock that cannot be removed is left; the caller has nothing to do about it.
pub fn release(lock : String, token : String) -> Unit {
  guard held_by(lock) is Some(current) else { return }
  guard current.get("token") is Some(String(held)) && held == token else {
    return
  }
  remove_file(lock) catch {
    _ => ()
  }
}

///|
const RETRY_MS = 50

///|
const WAIT_MS = 30000

///|
/// Runs `work` while holding a lock file that every process on the machine respects, waiting for one held by another.
/// A lock left by a dead process is taken over.
/// After `wait_ms` without the lock it fails with the reason the last attempt failed.
pub async fn[T] with_lock(
  directory : String,
  name : String,
  work : async () -> T raise @failure.TaskFailed,
  wait_ms~ : Int32 = WAIT_MS,
) -> T raise @failure.TaskFailed {
  io(() => prepare_directory(directory))
  let path = "\{directory}/\{name}.lock"
  let until = @async.now() + wait_ms.to_int64()
  while true {
    let taken = Some(acquire(path, "harnexus-crew adapter")) catch {
      failed => {
        if @async.now() >= until {
          @failure.fail("\{path} stayed locked: \{failed.message()}")
        }
        None
      }
    }
    guard taken is Some(token) else { @async.sleep(RETRY_MS) }
    defer release(path, token)
    return work()
  }
  abort("unreachable")
}

///|
/// The JSON object a lock or its takeover file holds, or None when it is missing, unreadable, or not an object.
fn held_by(path : String) -> Map[String, Json]? {
  try {
    match load(path) {
      Object(members) => Some(members)
      _ => None
    }
  } catch {
    _ => None
  }
}

///|
fn dead(holder : Map[String, Json]) -> Bool {
  match holder.get("pid") {
    Some(Number(pid, ..)) => !process_alive(pid)
    _ => false
  }
}

///|
fn abandoned_takeover(lock : String, takeover : String) -> String {
  "a run that was taking over this session died before it finished, and left \{lock} and \{takeover}. " +
  "Once every review and question process for this session has stopped, remove \{takeover}, then run again"
}

///|
/// Takes the lock over from a dead holder: true when this run removed the lock it had observed.
fn reap(lock : String, observed : String) -> Bool raise @failure.TaskFailed {
  // A second exclusive file marks the takeover, so of several runs only one removes the lock, and only the one it saw.
  let takeover = "\{lock}.reap"
  let pid = Json::number(current_pid().to_double())
  let marker = @jsonio.stringify(Json::object(Map::from_array([("pid", pid)])))
  let made = io(() => write_exclusive(takeover, marker))
  if !made {
    // Only the run that made the marker removes it: a second run deleting a dead marker could delete one made since, and two runs would then hold the lock.
    if held_by(takeover) is Some(owner) && dead(owner) {
      @failure.fail(abandoned_takeover(lock, takeover))
    }
    return false
  }
  let same = match held_by(lock) {
    Some(now) =>
      now.get("token") is Some(String(token)) && token == observed && dead(now)
    None => false
  }
  let removal = try {
    if same {
      io(() => remove_file(lock))
    }
    None
  } catch {
    failed => Some(failed)
  }
  let release_failure = try {
    io(() => remove_file(takeover))
    None
  } catch {
    failed => Some(failed)
  }
  if removal is Some(failed) {
    raise failed
  }
  if release_failure is Some(failed) {
    raise failed
  }
  same
}

///|
/// What `String(value)` gives in JS for a member that may be absent, to compare a token as the TypeScript lock does.
fn js_text(value : Json?) -> String {
  match value {
    None => "undefined"
    Some(Null) => "null"
    Some(String(text)) => text
    Some(Array(items)) =>
      items
      .map(item => if item is Null { "" } else { js_text(Some(item)) })
      .join(",")
    Some(Object(_)) => "[object Object]"
    Some(other) => @jsonio.stringify(other)
  }
}
