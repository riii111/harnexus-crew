///|
fn lock_in(directory : String) -> String {
  "\{directory}/lock.json"
}

///|
/// Writes a lock file as another run would have left it.
fn write_lock(lock : String, pid : Double, token : String) -> Unit raise {
  let content = Json::object(
    Map::from_array([("pid", Json::number(pid)), ("token", Json::string(token))]),
  )
  write_atomic(lock, content.stringify())
}

///|
fn read_lock_token(lock : String) -> String raise {
  match read_json_or_null(lock) {
    Object(members) =>
      match members.get("token") {
        Some(String(token)) => token
        _ => fail("no token")
      }
    _ => fail("not a lock")
  }
}

///|
async test "acquire writes the pid, token and start time of the holder" {
  in_scratch(directory => {
    let lock = lock_in(directory)
    let token = acquire(lock, "review")
    match read_json_or_null(lock) {
      Object(members) => {
        assert_eq(
          members.get("pid"),
          Some(Json::number(current_pid().to_double())),
        )
        assert_eq(members.get("token"), Some(Json::string(token)))
        match members.get("startedAt") {
          Some(String(at)) => assert_eq(at.length(), 24)
          _ => fail("no startedAt")
        }
        assert_eq(members.length(), 3)
      }
      _ => fail("not a lock")
    }
  })
}

///|
async test "acquire names the lock and the marker of a dead taker when it refuses" {
  in_scratch(directory => {
    let lock = lock_in(directory)
    let marker = "\{lock}.reap"
    write_lock(lock, dead_pid, "dead")
    write_atomic(marker, "{\"pid\":\{dead_pid.to_int() + 1}}")

    let message = task_failure(() => ignore(acquire(lock, "review")))

    assert_eq(
      message,
      "a run that was taking over this session died before it finished, and left \{lock} and \{marker}. Once every review and question process for this session has stopped, remove \{marker}, then run again",
    )
  })
}

///|
async test "acquire leaves a dead taker's marker and the lock for the owner to clear" {
  in_scratch(directory => {
    let lock = lock_in(directory)
    let marker = "\{lock}.reap"
    let marker_content = "{\"pid\":\{dead_pid.to_int() + 1}}"
    write_lock(lock, dead_pid, "dead")
    write_atomic(marker, marker_content)

    let message = task_failure(() => ignore(acquire(lock, "review")))

    assert_true(message != "")
    assert_eq(read_lock_token(lock), "dead")
    assert_eq(read_text(marker), marker_content)
  })
}

///|
async test "acquire refuses while a live run holds the takeover marker" {
  in_scratch(directory => {
    let lock = lock_in(directory)
    let marker = "\{lock}.reap"
    write_lock(lock, dead_pid, "dead")
    write_atomic(marker, "{\"pid\":\{current_pid()}}")

    let message = task_failure(() => ignore(acquire(lock, "review")))

    assert_eq(message, "another review is taking over this session")
    assert_true(is_file(marker))
    assert_eq(read_lock_token(lock), "dead")
  })
}

///|
async test "acquire does not take a lock whose holder cannot be told dead" {
  in_scratch(directory => {
    let lock = lock_in(directory)
    for
      content in [
        "{}", "{\"pid\":\"7\"}", "{\"token\":\"t\"}", "[1]", "not json",
      ] {
      write_atomic(lock, content)
      assert_eq(
        task_failure(() => ignore(acquire(lock, "review"))),
        "another review is using this session",
        msg=content,
      )
      assert_eq(read_text(lock), content, msg=content)
    }
  })
}

///|
async test "acquire names the pid of the holder when the pid is a number" {
  in_scratch(directory => {
    let lock = lock_in(directory)
    write_atomic(lock, "{\"pid\":\{current_pid()}}")

    assert_eq(
      task_failure(() => ignore(acquire(lock, "launch"))),
      "another launch (pid \{current_pid()}) is using this session",
    )
  })
}

///|
async test "acquire leaves the pid out of the message when the pid is not a number" {
  in_scratch(directory => {
    let lock = lock_in(directory)
    write_atomic(lock, "{\"pid\":\"x\"}")

    assert_eq(
      task_failure(() => ignore(acquire(lock, "launch"))),
      "another launch is using this session",
    )
  })
}

///|
async test "release removes the lock its token took" {
  in_scratch(directory => {
    let lock = lock_in(directory)
    let mine = acquire(lock, "review")
    assert_true(is_file(lock))

    release(lock, mine)

    assert_false(path_exists(lock))
  })
}

///|
async test "release leaves a lock another run took in the meantime" {
  in_scratch(directory => {
    let lock = lock_in(directory)
    let mine = acquire(lock, "review")
    write_lock(lock, current_pid().to_double(), "other")

    release(lock, mine)

    assert_eq(read_lock_token(lock), "other")
  })
}

///|
async test "release does nothing for a lock that is gone" {
  in_scratch(directory => {
    release(lock_in(directory), "token")

    assert_eq(list_names(directory), [])
  })
}

///|
async test "with_lock releases the lock when the work fails" {
  in_scratch(directory => {
    let lock = "\{directory}/chats.lock"
    let mut held = false

    let message = try {
      with_lock(directory, "chats", () => {
        held = is_file(lock)
        (@failure.fail("work failed") : Unit)
      })
      ""
    } catch {
      failed => failed.message()
    }

    assert_eq(message, "work failed")
    assert_true(held)
    assert_false(path_exists(lock))
  })
}

///|
async test "with_lock releases the lock when the work returns" {
  in_scratch(directory => {
    let lock = "\{directory}/chats.lock"

    let held = with_lock(directory, "chats", () => is_file(lock))

    assert_true(held)
    assert_false(path_exists(lock))
  })
}

///|
async test "with_lock waits for a lock released while it waits" {
  in_scratch(directory => {
    let lock = "\{directory}/chats.lock"
    let held = acquire(lock, "other")
    let mut released = false
    let mut ran_after_release = false

    @async.with_task_group(group => {
      group.spawn_bg(() => {
        @async.sleep(150)
        released = true
        release(lock, held)
      })
      ran_after_release = with_lock(
        directory,
        "chats",
        () => released,
        wait_ms=5000,
      )
    })

    assert_true(ran_after_release)
  })
}

///|
async test "with_lock reports an abandoned takeover marker once the wait is over" {
  in_scratch(directory => {
    let lock = "\{directory}/chats.lock"
    write_lock(lock, dead_pid, "dead")
    write_atomic("\{lock}.reap", "{\"pid\":\{dead_pid.to_int() + 1}}")

    let message = try {
      ignore(with_lock(directory, "chats", () => 1, wait_ms=100))
      ""
    } catch {
      failed => failed.message()
    }

    assert_eq(
      message,
      "\{lock} stayed locked: a run that was taking over this session died before it finished, and left \{lock} and \{lock}.reap. Once every review and question process for this session has stopped, remove \{lock}.reap, then run again",
    )
  })
}
