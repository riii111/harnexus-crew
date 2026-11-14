///|
const RETRY_MS = 50

///|
const WAIT_MS = 30000

///|
/// Runs `work` while holding a lock file that every process on the machine respects, waiting for one held by another.
/// After `wait_ms` without the lock it fails with the reason the last attempt failed.
pub async fn[T] with_lock(
  directory : String,
  name : String,
  work : async () -> T raise @failure.TaskFailed,
  wait_ms~ : Int32 = WAIT_MS,
) -> T raise @failure.TaskFailed {
  lift_file_failure(() => prepare_directory(directory))
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
/// Takes the lock at once or fails; the returned token proves it is this run's lock when releasing.
/// A lock whose holder died is taken over, and of several runs doing that only one removes the lock.
pub fn acquire(
  lock : String,
  holder : String,
) -> String raise @failure.TaskFailed {
  let token = new_uuid()

  // The first attempt may find a dead holder's lock, which is removed and then created by the second attempt.
  for _ in 0..<2 {
    let content : Map[String, Json] = Map::from_array([
      ("pid", Json::number(current_pid().to_double())),
      ("token", Json::string(token)),
      ("startedAt", Json::string(now_iso())),
    ])

    let created = lift_file_failure(() => {
      write_exclusive(lock, Json::object(content).stringify())
    })

    if created {
      return token
    }

    let held = read_holder(lock)
    guard held is Some(current) && is_dead_holder(current) else {
      let pid = match held {
        Some({ "pid": Number(pid, ..), .. }) =>
          " (pid \{Json::number(pid).stringify()})"
        _ => ""
      }

      @failure.fail("another \{holder}\{pid} is using this session")
    }

    if !reap(lock, current.get("token")) {
      @failure.fail("another \{holder} is taking over this session")
    }
  }

  @failure.fail("cannot take \{lock}")
}

///|
/// Releases the lock only if it is still the one `token` took, so a lock another run holds now stays.
pub fn release(lock : String, token : String) -> Unit {
  guard read_holder(lock) is Some(current) else { return }
  guard current.get("token") is Some(String(held)) && held == token else {
    return
  }
  remove_file(lock) catch {
    // A failed removal leaves the lock, because the caller has no way to handle it.
    _ => ()
  }
}

///|
/// Reports whether this run removed the observed lock.
fn reap(lock : String, observed : Json?) -> Bool raise @failure.TaskFailed {
  // Of several runs only one may remove the lock, and only the one it saw, so a second exclusive file marks the takeover.
  let takeover = "\{lock}.reap"
  let pid = Json::number(current_pid().to_double())
  let marker = Json::object({ "pid": pid }).stringify()
  let made = lift_file_failure(() => write_exclusive(takeover, marker))
  if !made {
    // A second run deleting a dead marker could delete one made since, and two runs would then hold the lock, so only the run that made the marker removes it.
    if read_holder(takeover) is Some(owner) && is_dead_holder(owner) {
      @failure.fail(abandoned_takeover(lock, takeover))
    }

    return false
  }

  let reclaimable = match read_holder(lock) {
    Some(now) => now.get("token") == observed && is_dead_holder(now)
    None => false
  }

  let lock_failure = if reclaimable { try_remove_file(lock) } else { None }
  // A failed removal of the lock must not leave the marker behind, because the marker would block every later takeover, so both removals run before either failure is raised.
  let takeover_failure = try_remove_file(takeover)

  if lock_failure is Some(failed) {
    raise failed
  }

  if takeover_failure is Some(failed) {
    raise failed
  }

  reclaimable
}

///|
fn try_remove_file(path : String) -> @failure.TaskFailed? {
  try {
    lift_file_failure(() => remove_file(path))
    None
  } catch {
    failed => Some(failed)
  }
}

///|
/// None when the holder's record cannot be read.
fn read_holder(path : String) -> Map[String, Json]? {
  try {
    match read_json_or_null(path) {
      Object(members) => Some(members)
      _ => None
    }
  } catch {
    _ => None
  }
}

///|
fn is_dead_holder(holder : Map[String, Json]) -> Bool {
  match holder.get("pid") {
    Some(Number(pid, ..)) => !is_process_alive(pid)
    _ => false
  }
}

///|
fn abandoned_takeover(lock : String, takeover : String) -> String {
  "a run that was taking over this session died before it finished, and left \{lock} and \{takeover}. " +
  "Once every review and question process for this session has stopped, remove \{takeover}, then run again"
}
