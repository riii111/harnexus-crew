///|
fn exists(path : String) -> Bool {
  @store.path_exists(path)
}

///|
async test "a run that finds a pending record by another run stops before the app is called" {
  with_rig("s-5", [done("w1")], rig => {
    let path = rig.write_launch_file()
    rig.another_run_writes_pending()

    assert_eq(
      rig.launch_failure(path),
      "another harnexus-crew run is sending; inspect \{rig.launch_dir()}/pending.json",
    )
    assert_eq(rig.calls.length(), 0)
  })
}

///|
async test "a run that finds a pending record by another run leaves that record in place" {
  with_rig("s-5k", [done("w1")], rig => {
    let path = rig.write_launch_file()
    rig.another_run_writes_pending()
    assert_eq(
      rig.launch_failure(path),
      "another harnexus-crew run is sending; inspect \{rig.launch_dir()}/pending.json",
    )

    assert_eq(
      show(read_state("\{rig.launch_dir()}/pending.json")),
      "{\"status\":\"sending\",\"tool\":\"create_thread\"}",
    )
  })
}

///|
async test "a run whose state was written by another run in between sends nothing" {
  with_rig("s-6", [done("w1")], rig => {
    let path = rig.write_launch_file()
    rig.another_run_writes_state()

    assert_eq(rig.launch_failure(path), STATE_CHANGED)
    assert_eq(rig.calls.length(), 0)
  })
}

///|
async test "a run whose state was written by another run in between releases its record" {
  with_rig("s-6r", [done("w1")], rig => {
    let path = rig.write_launch_file()
    rig.another_run_writes_state()
    assert_eq(rig.launch_failure(path), STATE_CHANGED)

    assert_false(exists("\{rig.launch_dir()}/pending.json"))
  })
}

///|
async test "an outcome after which the app surely did nothing releases the record" {
  for outcome in ["not_sent", "rejected", "invalid", "unsupported"] {
    with_rig(
      "s-7",
      [
        bridge_answer(
          @jsonio.parse("{\"outcome\":\"\{outcome}\",\"error\":\"x\"}"),
        ),
      ],
      rig => {
        let path = rig.write_launch_file()

        assert_eq(
          rig.launch_failure(path),
          "create_thread was not sent: {\"outcome\":\"\{outcome}\",\"error\":\"x\"}",
          msg=outcome,
        )
        assert_false(exists("\{rig.launch_dir()}/pending.json"), msg=outcome)
      },
    )
  }
}

///|
async test "an outcome after which the app may have acted keeps the record as unknown with its thread" {
  for outcome in ["unknown", "chat_not_opened", "queued"] {
    with_rig("s-8", [unknown_answer(outcome)], rig => {
      let path = rig.write_launch_file()

      assert_eq(rig.launch_failure(path), unknown_message(outcome), msg=outcome)
      let pending = read_state("\{rig.launch_dir()}/pending.json")
      assert_eq(
        show(@jsonio.field(pending, "status")),
        "\"unknown\"",
        msg=outcome,
      )
      assert_eq(show(@jsonio.field(pending, "threadId")), "\"w1\"", msg=outcome)
    })
  }
}

///|
async test "a kept record blocks the next run, and the app is not asked again" {
  for outcome in ["unknown", "chat_not_opened", "queued"] {
    with_rig("s-9", [unknown_answer(outcome)], rig => {
      let path = rig.write_launch_file()
      assert_eq(rig.launch_failure(path), unknown_message(outcome), msg=outcome)

      assert_eq(
        rig.launch_failure(path),
        "previous create_thread ended as unknown; never resend. Ask the user to check the App, then run resolve --sent or --not-sent",
        msg=outcome,
      )
      assert_eq(rig.calls.length(), 1, msg=outcome)
    })
  }
}

///|
async test "a confirmed answer that cannot be recorded keeps the record with the thread, for resolve" {
  with_rig("s-11", [done("w1")], rig => {
    let path = rig.write_launch_file()
    rig.before_save = (record, exclusive) => {
      if !exclusive && record.has_suffix("/state.json") {
        @failure.fail("cannot write \{record} (EROFS)")
      }
    }
    let message = rig.launch_failure(path)
    assert_eq(message, "cannot write \{rig.launch_dir()}/state.json (EROFS)")
    let pending = read_state("\{rig.launch_dir()}/pending.json")
    assert_eq(show(@jsonio.field(pending, "status")), "\"unknown\"")
    assert_eq(show(@jsonio.field(pending, "threadId")), "\"w1\"")
    assert_eq(
      show(@jsonio.field(@jsonio.field(pending, "answer"), "outcome")),
      "\"done\"",
    )
    assert_false(exists("\{rig.launch_dir()}/state.json"))
  })
}

///|
async test "a review refuses a changed base branch" {
  with_rig("s-16", [done("r1"), done("r1")], rig => {
    let (_, other) = rig.moved_review()

    assert_eq(rig.review_failure(other), BASE_CHANGED)
    assert_eq(rig.calls.length(), 1)
    assert_false(exists("\{rig.review_dir()}/pending.json"))
  })
}

///|
async test "a review takes a changed base branch once the base is updated" {
  with_rig("s-16u", [done("r1"), done("r1")], rig => {
    let (_, other) = rig.moved_review()
    assert_eq(rig.review_failure(other), BASE_CHANGED)

    ignore(
      review_in(
        rig.context([]),
        review_args(other, extra=["--update-base"]),
        rig.review_cloud(),
      ),
    )

    let kept = read_state("\{rig.review_dir()}/state.json")
    assert_eq(
      show(@jsonio.field(@jsonio.field(kept, "candidate"), "base")),
      "\"\{HEAD_1}\"",
    )
    assert_eq(
      show(@jsonio.field(@jsonio.field(kept, "candidate"), "baseBranch")),
      "\"other\"",
    )
  })
}

///|
async test "once the base is updated the previous base branch counts as a change in its turn" {
  with_rig("s-16p", [done("r1"), done("r1")], rig => {
    let (path, other) = rig.moved_review()
    assert_eq(rig.review_failure(other), BASE_CHANGED)
    ignore(
      review_in(
        rig.context([]),
        review_args(other, extra=["--update-base"]),
        rig.review_cloud(),
      ),
    )

    assert_eq(rig.review_failure(path), BASE_CHANGED)
  })
}

///|
async test "a review in T3 Code creates the reviewer thread in a review project of its own" {
  with_rig("s-16t", [done("t3-r1")], rig => {
    rig.t3_review()

    let (caller, tool, args) = rig.calls[0]
    assert_eq((caller, tool), ("t3-w", "create_thread"))
    assert_eq(
      show(@jsonio.field(Json::object(args), "target")),
      "{\"type\":\"project\",\"projectId\":\"\{rig.root}/review-home\",\"environment\":{\"type\":\"local\"}}",
    )
  })
}

///|
async test "a review in T3 Code names a model but no thinking level" {
  with_rig("s-16n", [done("t3-r1")], rig => {
    rig.t3_review()

    let (_, _, args) = rig.calls[0]
    assert_true(args.contains("model"))
    assert_false(args.contains("thinking"))
  })
}

///|
async test "a review in T3 Code addresses its prompt to T3" {
  with_rig("s-16a", [done("t3-r1")], rig => {
    rig.t3_review()

    assert_eq(rig.prompts, ["reviewer:T3"])
  })
}

///|
async test "a review in T3 Code refuses a worker that is not the thread it runs in" {
  with_rig("s-16w", [done("t3-r1")], rig => {
    rig.t3_review()
    let other = rig.write_review_file(extra=",\"workerChatId\":\"other\"")

    assert_eq(
      rig.review_failure(other, env=[("T3CODE_THREAD_ID", "t3-w")]),
      "workerChatId in the request must equal T3CODE_THREAD_ID",
    )
  })
}

///|
async test "a request that keeps the recorded members is accepted whatever else it adds" {
  let recorded = recorded_session()
  let kept = kept_session()
  assert_eq(
    @apptestkit.failure_of(() => check_kept(recorded, kept, app_session_keys)),
    "",
  )
}

///|
async test "only the members named are compared, so a Cloud review may differ in the others" {
  let recorded = recorded_session()
  let cloud = @jsonio.parse(
    "{\"taskId\":\"TR1\",\"workerAI\":\"Codex\",\"checkout\":\"/c\"}",
  )
  assert_eq(
    @apptestkit.failure_of(() => {
      check_kept(recorded, cloud, ["taskId", "workerAI", "checkout"])
    }),
    "",
  )
  assert_eq(
    @apptestkit.failure_of(() => check_kept(recorded, cloud, app_session_keys)),
    "review session must keep the original workerChatId",
  )
}

///|
async test "a request that changes the task, worker, chat, project or checkout is refused" {
  let recorded = recorded_session()
  let kept = kept_session()
  for key in ["taskId", "workerAI", "workerChatId", "projectId", "checkout"] {
    let changed = with_member(kept, key, Json::string("other"))
    assert_eq(
      @apptestkit.failure_of(() => {
        check_kept(recorded, changed, app_session_keys)
      }),
      "review session must keep the original \{key}",
      msg=key,
    )
  }
}

///|
async test "a recorded session that has no project differs from one that names it" {
  let legacy = @jsonio.parse(
    "{\"taskId\":\"TR1\",\"workerAI\":\"Codex\",\"workerChatId\":\"w1\",\"checkout\":\"/c\"}",
  )
  let kept = kept_session()
  assert_eq(
    @apptestkit.failure_of(() => check_kept(legacy, kept, app_session_keys)),
    "review session must keep the original projectId",
  )
}

///|
async test "a review answered by another thread than the recorded reviewer is refused" {
  with_rig("s-17", [done("r1"), done("r2")], rig => {
    let path = rig.reviewed_once()

    assert_eq(
      rig.review_failure(path),
      "review session must keep the same reviewer",
    )
  })
}

///|
async test "a review answered by another thread than the recorded reviewer is kept as unknown with its thread" {
  with_rig("s-17k", [done("r1"), done("r2")], rig => {
    let path = rig.reviewed_once()
    assert_eq(
      rig.review_failure(path),
      "review session must keep the same reviewer",
    )

    let pending = read_state("\{rig.review_dir()}/pending.json")
    assert_eq(show(@jsonio.field(pending, "status")), "\"unknown\"")
    assert_eq(show(@jsonio.field(pending, "threadId")), "\"r2\"")
  })
}

///|
async test "a review answered by the worker's own thread is refused" {
  with_rig("s-18", [done("w1")], rig => {
    let path = rig.write_review_file()

    assert_eq(rig.review_failure(path), "a worker cannot review itself")
  })
}

///|
const STATE_CHANGED : String = "another harnexus-crew run changed the state; rerun to check it"

///|
const BASE_CHANGED : String = "baseBranch changed; use --update-base after integrating upstream"

///|
async fn Rig::launch_failure(self : Rig, path : String) -> String {
  @apptestkit.failure_of(() => {
    ignore(launch_in(self.context([]), launch_args(path)))
  })
}

///|
async fn Rig::review_failure(
  self : Rig,
  path : String,
  env~ : Array[(String, String)] = [],
) -> String {
  @apptestkit.failure_of(() => {
    ignore(review_in(self.context(env), review_args(path), self.review_cloud()))
  })
}

///|
fn Rig::another_run_writes_pending(self : Rig) -> Unit {
  self.before_save = (record, exclusive) => {
    if exclusive {
      write_text(record, "{\"status\":\"sending\",\"tool\":\"create_thread\"}")
    }
  }
}

///|
fn Rig::another_run_writes_state(self : Rig) -> Unit {
  let state = "\{self.launch_dir()}/state.json"
  self.before_save = (record, exclusive) => {
    if exclusive {
      @store.write_atomic(record, "{}") catch {
        _ => ()
      }
      @store.remove_file(record) catch {
        _ => ()
      }
      write_text(state, "{\"threadId\":\"w9\"}")
    }
  }
}

///|
async fn Rig::reviewed_once(self : Rig) -> String {
  let path = self.write_review_file()
  ignore(review_in(self.context([]), review_args(path), self.review_cloud()))
  self.head.val = HEAD_2
  path
}

///|
async fn Rig::moved_review(self : Rig) -> (String, String) {
  let path = self.reviewed_once()
  let other = "\{self.root}/other.json"
  write_text(
    other,
    "{\"taskId\":\"TR1\",\"workerAI\":\"Codex\",\"projectId\":\"project\",\"checkout\":\"\{self.checkout()}\",\"baseBranch\":\"other\",\"documentRefs\":[\"https://example.com/task\"],\"prUrl\":null}",
  )
  (path, other)
}

///|
async fn Rig::t3_review(self : Rig) -> Unit {
  self.checkout_path = "\{self.root}/.t3/worktrees/ab12/repo"
  let path = self.write_review_file()
  ignore(
    review_in(
      self.context([("T3CODE_THREAD_ID", "t3-w")]),
      review_args(path),
      self.review_cloud(),
    ),
  )
}

///|
fn unknown_answer(outcome : String) -> @bridge.CallAnswer raise {
  bridge_answer(
    @jsonio.parse("{\"outcome\":\"\{outcome}\",\"threadId\":\"w1\"}"),
  )
}

///|
fn unknown_message(outcome : String) -> String {
  "create_thread result is unknown ({\"outcome\":\"\{outcome}\",\"threadId\":\"w1\"}); never resend. Ask the user to check the App"
}

///|
fn recorded_session() -> Json raise {
  @jsonio.parse(
    "{\"taskId\":\"TR1\",\"workerAI\":\"Codex\",\"workerChatId\":\"w1\",\"projectId\":\"p\",\"checkout\":\"/c\"}",
  )
}

///|
fn kept_session() -> Json raise {
  @jsonio.parse(
    "{\"taskId\":\"TR1\",\"workerAI\":\"Codex\",\"workerChatId\":\"w1\",\"projectId\":\"p\",\"checkout\":\"/c\",\"head\":\"x\"}",
  )
}

///|
fn with_member(request : Json, key : String, value : Json) -> Json {
  match request {
    Object(members) => {
      let copy = Map::from_array(members.to_array())
      copy[key] = value
      Json::object(copy)
    }
    other => other
  }
}
