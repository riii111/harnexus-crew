///|
fn exists(path : String) -> Bool {
  @store.path_exists(path)
}

///|
async test "a run that finds a pending record by another run stops before the app is called" {
  with_rig("s-5", [done("w1")], rig => {
    let path = rig.write_launch_file()
    // Another run creates its record between this run's reading and its own writing.
    rig.before_save = (record, exclusive) => {
      if exclusive {
        write_text(
          record, "{\"status\":\"sending\",\"tool\":\"create_thread\"}",
        )
      }
    }
    let message = failure_of(() => {
      ignore(launch_in(rig.context([]), launch_args(path)))
    })
    assert_eq(
      message,
      "another harnexus-crew run is sending; inspect \{rig.launch_dir()}/pending.json",
    )
    assert_eq(rig.calls.length(), 0)
    // The other run's record is not this run's to remove.
    assert_true(exists("\{rig.launch_dir()}/pending.json"))
  })
}

///|
async test "a run whose state was written by another run in between releases its record and sends nothing" {
  with_rig("s-6", [done("w1")], rig => {
    let path = rig.write_launch_file()
    rig.before_save = (record, exclusive) => {
      if exclusive {
        // The record is made, then the other run writes its state.
        @store.write_atomic(record, "{}") catch {
          _ => ()
        }
        @store.remove_file(record) catch {
          _ => ()
        }
        write_text("\{rig.launch_dir()}/state.json", "{\"threadId\":\"w9\"}")
      }
    }
    let message = failure_of(() => {
      ignore(launch_in(rig.context([]), launch_args(path)))
    })
    assert_eq(
      message, "another harnexus-crew run changed the state; rerun to check it",
    )
    assert_eq(rig.calls.length(), 0)
    assert_false(exists("\{rig.launch_dir()}/pending.json"))
  })
}

///|
async test "outcomes after which the app surely did nothing release the record, the others keep it" {
  let unsent = ["not_sent", "rejected", "invalid", "unsupported"]
  for outcome in unsent {
    with_rig(
      "s-7",
      [
        bridge_answer(
          @jsonio.parse("{\"outcome\":\"\{outcome}\",\"error\":\"x\"}"),
        ),
      ],
      rig => {
        let path = rig.write_launch_file()
        let message = failure_of(() => {
          ignore(launch_in(rig.context([]), launch_args(path)))
        })
        assert_eq(
          message,
          "create_thread was not sent: {\"outcome\":\"\{outcome}\",\"error\":\"x\"}",
        )
        assert_false(exists("\{rig.launch_dir()}/pending.json"))
      },
    )
  }
  for outcome in ["unknown", "chat_not_opened", "queued"] {
    with_rig(
      "s-8",
      [
        bridge_answer(
          @jsonio.parse("{\"outcome\":\"\{outcome}\",\"threadId\":\"w1\"}"),
        ),
      ],
      rig => {
        let path = rig.write_launch_file()
        let message = failure_of(() => {
          ignore(launch_in(rig.context([]), launch_args(path)))
        })
        assert_true(message.contains("create_thread result is unknown"))
        assert_true(message.contains("never resend"))
        let pending = read_state("\{rig.launch_dir()}/pending.json")
        assert_eq(show(@jsonio.field(pending, "status")), "\"unknown\"")
        assert_eq(show(@jsonio.field(pending, "threadId")), "\"w1\"")
        // The next run is blocked, and the app is not asked again.
        let blocked = failure_of(() => {
          ignore(launch_in(rig.context([]), launch_args(path)))
        })
        assert_eq(
          blocked, "previous create_thread ended as unknown; never resend. Ask the user to check the App, then run resolve --sent or --not-sent",
        )
        assert_eq(rig.calls.length(), 1)
      },
    )
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
    let message = failure_of(() => {
      ignore(launch_in(rig.context([]), launch_args(path)))
    })
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
async test "a review refuses a changed base branch until the base is updated" {
  with_rig("s-16", [done("r1"), done("r1")], rig => {
    let path = rig.write_review_file()
    ignore(review_in(rig.context([]), review_args(path), rig.review_cloud()))
    rig.head.val = HEAD_2
    let other = "\{rig.root}/other.json"
    write_text(
      other,
      "{\"taskId\":\"TR1\",\"workerAI\":\"Codex\",\"projectId\":\"project\",\"checkout\":\"\{rig.checkout()}\",\"baseBranch\":\"other\",\"documentRefs\":[\"https://example.com/task\"],\"prUrl\":null}",
    )
    let changed = "baseBranch changed; use --update-base after integrating upstream"
    assert_eq(
      failure_of(() => {
        ignore(
          review_in(rig.context([]), review_args(other), rig.review_cloud()),
        )
      }),
      changed,
    )
    assert_eq(rig.calls.length(), 1)
    assert_false(exists("\{rig.review_dir()}/pending.json"))
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
    // The base moved with the branch, so the old branch is a change in its turn.
    assert_eq(
      failure_of(() => {
        ignore(
          review_in(rig.context([]), review_args(path), rig.review_cloud()),
        )
      }),
      changed,
    )
  })
}

///|
async test "a review in T3 Code runs in its own project and answers through T3" {
  with_rig("s-16t", [done("t3-r1")], rig => {
    rig.checkout_path = "\{rig.root}/.t3/worktrees/ab12/repo"
    let path = rig.write_review_file()
    ignore(
      review_in(
        rig.context([("T3CODE_THREAD_ID", "t3-w")]),
        review_args(path),
        rig.review_cloud(),
      ),
    )
    let (caller, tool, args) = rig.calls[0]
    assert_eq((caller, tool), ("t3-w", "create_thread"))
    assert_false(args.contains("thinking"))
    assert_eq(
      show(@jsonio.field(Json::object(args), "target")),
      "{\"type\":\"project\",\"projectId\":\"\{rig.root}/review-home\",\"environment\":{\"type\":\"local\"}}",
    )
    assert_eq(rig.prompts, ["reviewer:T3"])
    // A worker that is not the thread this runs in is refused in T3 Code's own terms.
    let other = rig.write_review_file(extra=",\"workerChatId\":\"other\"")
    assert_eq(
      failure_of(() => {
        ignore(
          review_in(
            rig.context([("T3CODE_THREAD_ID", "t3-w")]),
            review_args(other),
            rig.review_cloud(),
          ),
        )
      }),
      "workerChatId in the request must equal T3CODE_THREAD_ID",
    )
  })
}

///|
async test "a session keeps its task, worker, project and checkout" {
  let recorded = @jsonio.parse(
    "{\"taskId\":\"TR1\",\"workerAI\":\"Codex\",\"workerChatId\":\"w1\",\"projectId\":\"p\",\"checkout\":\"/c\"}",
  )
  let same = @jsonio.parse(
    "{\"taskId\":\"TR1\",\"workerAI\":\"Codex\",\"workerChatId\":\"w1\",\"projectId\":\"p\",\"checkout\":\"/c\",\"head\":\"x\"}",
  )
  check_kept(recorded, same, app_session_keys)
  // A Cloud review keeps fewer members, so the others may differ.
  check_kept(
    recorded,
    @jsonio.parse(
      "{\"taskId\":\"TR1\",\"workerAI\":\"Codex\",\"checkout\":\"/c\"}",
    ),
    ["taskId", "workerAI", "checkout"],
  )
  for key in ["taskId", "workerAI", "workerChatId", "projectId", "checkout"] {
    let changed = match same {
      Object(members) => {
        let copy = Map::from_array(members.to_array())
        copy[key] = Json::string("other")
        Json::object(copy)
      }
      other => other
    }
    assert_eq(
      failure_of(() => check_kept(recorded, changed, app_session_keys)),
      "review session must keep the original \{key}",
    )
  }
  // A recorded session that has no project differs from one that names it.
  let legacy = @jsonio.parse(
    "{\"taskId\":\"TR1\",\"workerAI\":\"Codex\",\"workerChatId\":\"w1\",\"checkout\":\"/c\"}",
  )
  assert_eq(
    failure_of(() => check_kept(legacy, same, app_session_keys)),
    "review session must keep the original projectId",
  )
}

///|
async test "the reviewer is the one that was recorded, and never the worker" {
  with_rig("s-17", [done("r1"), done("r2")], rig => {
    let path = rig.write_review_file()
    ignore(review_in(rig.context([]), review_args(path), rig.review_cloud()))
    rig.head.val = HEAD_2
    assert_eq(
      failure_of(() => {
        ignore(
          review_in(rig.context([]), review_args(path), rig.review_cloud()),
        )
      }),
      "review session must keep the same reviewer",
    )
    // The answer is kept as unknown with its thread, so it is settled by hand.
    let pending = read_state("\{rig.review_dir()}/pending.json")
    assert_eq(show(@jsonio.field(pending, "status")), "\"unknown\"")
    assert_eq(show(@jsonio.field(pending, "threadId")), "\"r2\"")
  })
  with_rig("s-18", [done("w1")], rig => {
    assert_eq(
      failure_of(() => {
        ignore(
          review_in(
            rig.context([]),
            review_args(rig.write_review_file()),
            rig.review_cloud(),
          ),
        )
      }),
      "a worker cannot review itself",
    )
  })
}
