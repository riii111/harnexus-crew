///|
/// The text of a record file, or "" when it is missing.
fn record_text(path : String) -> String {
  (@store.read_text_if_exists(path) catch { _ => None }).unwrap_or("")
}

///|
fn exists(path : String) -> Bool {
  @store.path_exists(path)
}

///|
async test "a launch writes its pending record before the app is called and the state after" {
  with_rig("s-1", [done("w1")], rig => {
    let path = rig.launch_file()
    let at_call = Ref::{ val: "", }
    rig.before_save = (_, _) => ()
    let ctx = rig.context([])
    let call = ctx.ports.call
    let watched : Ports = {
      call: (caller, tool, args) => {
        at_call.val = record_text("\{rig.launch_dir()}/pending.json")
        call(caller, tool, args)
      },
      save: ctx.ports.save,
    }
    let shown = launch_in({ ..ctx, ports: watched, }, launch_args(path))
    assert_true(at_call.val.contains("\"status\": \"sending\""))
    assert_eq(rig.calls.length(), 1)
    let (caller, tool, args) = rig.calls[0]
    assert_eq(caller, "w1")
    assert_eq(tool, "create_thread")
    assert_eq(
      show(Json::object(args)),
      "{\"prompt\":\"worker prompt for TR1\",\"target\":{\"type\":\"project\",\"projectId\":\"project\",\"environment\":{\"type\":\"worktree\"}},\"title\":\"Impl TR1\",\"model\":\"claude-sonnet-5-5\",\"thinking\":\"high\"}",
    )
    assert_false(exists("\{rig.launch_dir()}/pending.json"))
    assert_eq(
      show(shown),
      "{\"tool\":\"create_thread\",\"threadId\":\"w1\",\"model\":\"claude-sonnet-5-5\",\"effort\":\"high\",\"expected\":{\"model\":\"claude-sonnet-5-5\",\"effort\":\"high\"},\"state\":\"\{rig.launch_dir()}/state.json\"}",
    )
    let state = read_state("\{rig.launch_dir()}/state.json")
    assert_eq(show(field(state, "threadId")), "\"w1\"")
    assert_eq(show(field(state, "request")), launch_request_text())
  })
}

///|
async test "a launch names a starting branch in the worktree target and sends the options it was given" {
  with_rig("s-2", [done("w1")], rig => {
    let path = rig.launch_file(
      text="{\"taskId\":\"TR1\",\"documentRefs\":[\"https://example.com/task\"],\"completionTarget\":\"merge\",\"projectId\":\"project\",\"startingBranch\":\"feat/x\",\"displayName\":\"Named\"}",
    )
    ignore(
      launch_in(
        rig.context([]),
        launch_args(path, extra=["--model", "m", "--thinking", "low"]),
      ),
    )
    let (_, _, args) = rig.calls[0]
    assert_eq(
      show(Json::object(args)),
      "{\"prompt\":\"worker prompt for TR1\",\"target\":{\"type\":\"project\",\"projectId\":\"project\",\"environment\":{\"type\":\"worktree\",\"startingState\":{\"type\":\"branch\",\"branchName\":\"feat/x\"}}},\"title\":\"Impl｜Named\",\"model\":\"m\",\"thinking\":\"low\"}",
    )
    let workspace = field(read_state("\{rig.launch_dir()}/state.json"), "sent")
    assert_true(show(field(workspace, "workspace")).contains("startingState"))
  })
}

///|
async test "T3 Code is not told a thinking unless one is asked for" {
  with_rig("s-3", [done("t1")], rig => {
    let path = rig.launch_file()
    ignore(
      launch_in(
        rig.context([("T3CODE_THREAD_ID", "t3-caller")]),
        launch_args(path),
      ),
    )
    let (caller, _, args) = rig.calls[0]
    assert_eq(caller, "t3-caller")
    assert_false(args.contains("thinking"))
  })
}

///|
async test "a launch for a task that has a worker finds it, whatever the task is called now" {
  with_rig("s-4", [done("w1")], rig => {
    ignore(launch_in(rig.context([]), launch_args(rig.launch_file())))
    let renamed = rig.launch_file(
      text="{\"taskId\":\"TR1\",\"documentRefs\":[\"https://example.com/task\"],\"completionTarget\":\"draft_pr\",\"projectId\":\"project\",\"displayName\":\"New\"}",
    )
    let again = launch_in(rig.context([]), launch_args(renamed))
    assert_eq(
      show(again),
      "{\"existing\":\"w1\",\"state\":\"\{rig.launch_dir()}/state.json\"}",
    )
    assert_eq(rig.calls.length(), 1)
    let different = rig.launch_file(
      text="{\"taskId\":\"TR1\",\"documentRefs\":[\"https://example.com/other\"],\"completionTarget\":\"draft_pr\",\"projectId\":\"project\"}",
    )
    assert_eq(
      failure_of(() => {
        ignore(launch_in(rig.context([]), launch_args(different)))
      }),
      "TR1 already has worker w1 launched with a different request",
    )
    assert_eq(rig.calls.length(), 1)
  })
}

///|
async test "a run that finds a pending record by another run stops before the app is called" {
  with_rig("s-5", [done("w1")], rig => {
    let path = rig.launch_file()
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
    let path = rig.launch_file()
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
        @call.CallAnswer::of_json(
          @jsonio.parse("{\"outcome\":\"\{outcome}\",\"error\":\"x\"}"),
        ),
      ],
      rig => {
        let path = rig.launch_file()
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
        @call.CallAnswer::of_json(
          @jsonio.parse("{\"outcome\":\"\{outcome}\",\"threadId\":\"w1\"}"),
        ),
      ],
      rig => {
        let path = rig.launch_file()
        let message = failure_of(() => {
          ignore(launch_in(rig.context([]), launch_args(path)))
        })
        assert_true(message.contains("create_thread result is unknown"))
        assert_true(message.contains("never resend"))
        let pending = read_state("\{rig.launch_dir()}/pending.json")
        assert_eq(show(field(pending, "status")), "\"unknown\"")
        assert_eq(show(field(pending, "threadId")), "\"w1\"")
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
async test "a lost create_thread answer without a thread is unsent, and a lost send_message answer is not" {
  with_rig(
    "s-9",
    [@call.CallAnswer::of_json(@jsonio.parse("{\"outcome\":\"tool_error\"}"))],
    rig => {
      let message = failure_of(() => {
        ignore(launch_in(rig.context([]), launch_args(rig.launch_file())))
      })
      assert_true(message.contains("create_thread was not sent"))
      assert_false(exists("\{rig.launch_dir()}/pending.json"))
    },
  )
  with_rig(
    "s-10",
    [
      done("r1"),
      @call.CallAnswer::of_json(@jsonio.parse("{\"outcome\":\"tool_error\"}")),
    ],
    rig => {
      let path = rig.review_file()
      ignore(review_in(rig.context([]), review_args(path), rig.review_cloud()))
      rig.head.val = HEAD_2
      let message = failure_of(() => {
        ignore(
          review_in(rig.context([]), review_args(path), rig.review_cloud()),
        )
      })
      assert_true(message.contains("send_message_to_thread result is unknown"))
      assert_true(exists("\{rig.review_dir()}/pending.json"))
    },
  )
}

///|
async test "a confirmed answer that cannot be recorded keeps the record with the thread, for resolve" {
  with_rig("s-11", [done("w1")], rig => {
    let path = rig.launch_file()
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
    assert_eq(show(field(pending, "status")), "\"unknown\"")
    assert_eq(show(field(pending, "threadId")), "\"w1\"")
    assert_eq(show(field(field(pending, "answer"), "outcome")), "\"done\"")
    assert_false(exists("\{rig.launch_dir()}/state.json"))
  })
}

///|
async test "a done answer without a usable thread keeps the record, and resolve names the thread" {
  for
    answer in [
      "{\"outcome\":\"done\"}", "{\"outcome\":\"done\",\"threadId\":\"w 1\"}", "{\"outcome\":\"done\",\"threadId\":7}",
    ] {
    with_rig("s-12", [@call.CallAnswer::of_json(@jsonio.parse(answer))], rig => {
      let path = rig.launch_file()
      let message = failure_of(() => {
        ignore(launch_in(rig.context([]), launch_args(path)))
      })
      assert_true(message.length() > 0)
      assert_eq(
        show(field(read_state("\{rig.launch_dir()}/pending.json"), "status")),
        "\"unknown\"",
      )
      let shown = resolve_in(
        rig.context([]),
        resolve_args(path, sent=true, thread="w2"),
      )
      assert_eq(show(field(shown, "threadId")), "\"w2\"")
      assert_false(exists("\{rig.launch_dir()}/pending.json"))
      assert_eq(
        show(field(read_state("\{rig.launch_dir()}/state.json"), "threadId")),
        "\"w2\"",
      )
    })
  }
}

///|
async test "a refused first turn is kept apart, never confirmed, and settled only as not sent" {
  let refused = @call.CallAnswer::of_json(
    @jsonio.parse(
      "{\"outcome\":\"model_mismatch\",\"threadId\":\"w1\",\"expected\":{\"model\":\"a\",\"effort\":\"high\"},\"actual\":{\"model\":\"b\"}}",
    ),
  )
  with_rig("s-13", [refused], rig => {
    let path = rig.launch_file()
    let message = failure_of(() => {
      ignore(launch_in(rig.context([]), launch_args(path)))
    })
    assert_eq(
      message, "thread w1 refused its first turn: asked for model b instead of a and did not say which effort (expected high); fix the model, then resolve --not-sent",
    )
    let pending = read_state("\{rig.launch_dir()}/pending.json")
    assert_eq(show(field(pending, "status")), "\"refused\"")
    assert_eq(
      failure_of(() => {
        ignore(resolve_in(rig.context([]), resolve_args(path, sent=true)))
      }),
      "a refused first turn never ran; use --not-sent",
    )
    let released = resolve_in(rig.context([]), resolve_args(path, sent=false))
    assert_eq(
      show(released),
      "{\"released\":\"create_thread\",\"status\":\"refused\"}",
    )
    assert_false(exists("\{rig.launch_dir()}/pending.json"))
    let history = read_state("\{rig.launch_dir()}/history.json")
    assert_eq(show(field(history, "0")), "null")
    let shown = state_request_in(rig.context([]), path)
    assert_eq(show(field(shown, "refusedThreadIds")), "[\"w1\"]")
  })
}

///|
async test "resolve settles what is pending and says so when nothing is" {
  with_rig("s-14", [], rig => {
    let path = rig.launch_file()
    for sent in [true, false] {
      assert_eq(
        failure_of(() => {
          ignore(resolve_in(rig.context([]), resolve_args(path, sent~)))
        }),
        "nothing is pending",
      )
    }
    assert_eq(
      failure_of(() => {
        ignore(
          resolve_in(
            rig.context([]),
            resolve_args(path, sent=true, thread="a b"),
          ),
        )
      }),
      "--thread-id must be a confirmed chat ID without whitespace",
    )
  })
}

///|
async test "a review creates its reviewer once, sends a new head to the same reviewer and keeps the base" {
  with_rig(
    "s-15",
    [done("r1", model="gpt-6.1-sol", effort="medium"), done("r1")],
    rig => {
      let path = rig.review_file()
      let first = review_in(
        rig.context([]),
        review_args(path),
        rig.review_cloud(),
      )
      assert_eq(show(field(first, "threadId")), "\"r1\"")
      let (caller, tool, args) = rig.calls[0]
      assert_eq(caller, "w1")
      assert_eq(tool, "create_thread")
      assert_eq(
        show(Json::object(args)),
        "{\"prompt\":\"reviewer prompt for TR1\",\"target\":{\"type\":\"project\",\"projectId\":\"p-review\",\"environment\":{\"type\":\"local\"}},\"title\":\"Review TR1\",\"model\":\"gpt-6.1-sol\",\"thinking\":\"medium\"}",
      )
      let state = read_state("\{rig.review_dir()}/state.json")
      assert_eq(show(field(field(state, "candidate"), "head")), "\"\{HEAD_1}\"")
      assert_eq(show(field(field(state, "candidate"), "base")), "\"\{BASE}\"")
      assert_eq(
        show(field(field(state, "candidate"), "workerChatId")),
        "\"w1\"",
      )

      // The same head is not sent twice.
      assert_eq(
        failure_of(() => {
          ignore(
            review_in(rig.context([]), review_args(path), rig.review_cloud()),
          )
        }),
        "head \{HEAD_1} was already sent to reviewer r1; wait for its result",
      )
      assert_eq(rig.calls.length(), 1)

      rig.head.val = HEAD_2
      let second = review_in(
        rig.context([]),
        review_args(path, extra=["--model", "m2"]),
        rig.review_cloud(),
      )
      assert_eq(show(field(second, "tool")), "\"send_message_to_thread\"")
      let (_, tool, args) = rig.calls[1]
      assert_eq(tool, "send_message_to_thread")
      assert_eq(
        show(Json::object(args)),
        "{\"prompt\":\"reviewer prompt for TR1\",\"threadId\":\"r1\",\"model\":\"m2\"}",
      )
      let kept = read_state("\{rig.review_dir()}/state.json")
      assert_eq(show(field(field(kept, "candidate"), "base")), "\"\{BASE}\"")
      assert_eq(show(field(field(kept, "candidate"), "head")), "\"\{HEAD_2}\"")
      let shown = state_request_in(rig.context([]), path)
      assert_eq(show(field(shown, "reviewerThreadId")), "\"r1\"")
      assert_eq(show(field(shown, "workerThreadId")), "\"w1\"")
      assert_eq(show(field(shown, "pendingHead")), "null")
    },
  )
}

///|
async test "a review refuses a changed base branch until the base is updated" {
  with_rig("s-16", [done("r1"), done("r1")], rig => {
    let path = rig.review_file()
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
    assert_eq(show(field(field(kept, "candidate"), "base")), "\"\{HEAD_1}\"")
    assert_eq(show(field(field(kept, "candidate"), "baseBranch")), "\"other\"")
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
    let path = rig.review_file()
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
      show(field(Json::object(args), "target")),
      "{\"type\":\"project\",\"projectId\":\"\{rig.root}/review-home\",\"environment\":{\"type\":\"local\"}}",
    )
    assert_eq(rig.prompts, ["reviewer:T3"])
    // A worker that is not the thread this runs in is refused in T3 Code's own terms.
    let other = rig.review_file(extra=",\"workerChatId\":\"other\"")
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
    let path = rig.review_file()
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
    assert_eq(show(field(pending, "status")), "\"unknown\"")
    assert_eq(show(field(pending, "threadId")), "\"r2\"")
  })
  with_rig("s-18", [done("w1")], rig => {
    assert_eq(
      failure_of(() => {
        ignore(
          review_in(
            rig.context([]),
            review_args(rig.review_file()),
            rig.review_cloud(),
          ),
        )
      }),
      "a worker cannot review itself",
    )
  })
}

///|
async test "a request names the worker's chat only as the thread it runs in" {
  with_rig("s-19", [], rig => {
    for
      extra in [
        ",\"workerChatId\":\"other\"", ",\"workerChatId\":null", ",\"workerChatId\":3",
      ] {
      let path = rig.review_file(extra~)
      assert_eq(
        failure_of(() => {
          ignore(
            review_in(rig.context([]), review_args(path), rig.review_cloud()),
          )
        }),
        "workerChatId in the request must equal CODEX_THREAD_ID",
      )
    }
  })
}

///|
async test "review asks for a reviewer in the cloud only in a Claude Code cloud session" {
  with_rig("s-20", [], rig => {
    let path = rig.review_file()
    let reached = Ref::{ val: 0, }
    let hook : async (@args.ReviewArgs) -> Json raise @failure.TaskFailed = args => {
      reached.val += 1
      Json::string(args.request)
    }
    let shown = review_in(
      rig.context([("CLAUDE_CODE_REMOTE", "true")]),
      review_args(path),
      hook,
    )
    assert_eq(show(shown), "\"\{path}\"")
    assert_eq(reached.val, 1)
    // Cloud without a Claude host, and local, never reach it.
    assert_eq(
      failure_of(() => {
        ignore(
          review_in(
            rig.context([("CODEX_ENVIRONMENT_ID", "x")]),
            review_args(path),
            hook,
          ),
        )
      }),
      "review needs the Codex App and is unavailable in Cloud. Cloud cannot create or resume other tasks or threads from here; PR notifications are not built for Cloud, so check the PR with gh",
    )
    assert_eq(
      failure_of(() => {
        ignore(
          review_in(
            rig.context([]),
            review_args(path, extra=["--ask", "q.md"]),
            hook,
          ),
        )
      }),
      "--ask applies to review only in a Claude Code cloud session",
    )
    assert_eq(
      failure_of(() => {
        ignore(
          review_in(
            rig.context([]),
            review_args(path, extra=["--recover", "discard"]),
            hook,
          ),
        )
      }),
      "--recover applies to review only in a Claude Code cloud session",
    )
    assert_eq(reached.val, 1)
  })
}
