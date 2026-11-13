///|
async test "the first head is reviewed by a new reviewer, whose answer is the result" {
  with_rig("first", rig => {
    rig.plan(1, out=events(REVIEWER, "判定: LGTM\n対象: …"))
    let done = rig.review()
    let state = rig.state_dir("example")
    assert_eq(
      show(done),
      "{\"status\":\"completed\",\"verdict\":\"LGTM\",\"taskId\":\"example\",\"base\":\"\{BASE}\",\"head\":\"\{HEAD_1}\",\"reviewer\":\"\{REVIEWER}\",\"answer\":\"判定: LGTM\\n対象: …\",\"state\":\"\{state}/state.json\"}",
    )
    assert_eq(rig.args(1), [
      "exec",
      "--json",
      "--sandbox",
      "read-only",
      "-C",
      rig.checkout,
      "-m",
      "gpt-6.1-sol",
      "-c",
      "model_reasoning_effort=\"medium\"",
      "-",
    ])
    assert_eq(
      rig.recorded("stdin", 1),
      "reviewer prompt for example at \{HEAD_1}",
    )
    assert_eq(@text.js_trim(rig.recorded("cwd", 1)), rig.checkout)
    let fields = rig.prompts[0]
    assert_eq(fields.get("reply_to"), Some("Cloud"))
    assert_eq(fields.get("worker_chat_id"), Some("worker-session"))
    let saved = read_state("\{state}/state.json")
    assert_eq(show(field(saved, "heads")), "[\"\{HEAD_1}\"]")
    assert_eq(show(field(saved, "verdict")), "\"LGTM\"")
    assert_eq(
      show(field(field(saved, "candidate"), "workerChatId")),
      "\"worker-session\"",
    )
    assert_false(rig.pending_exists("example"))
    assert_false(@store.path_exists("\{state}/lock.json"))
  })
}

///|
async test "a new head is reviewed by resuming the same reviewer in the checkout" {
  with_rig("resume", rig => {
    rig.plan(1, out=events(REVIEWER, "判定: 修正必要"))
    rig.plan(2, out=events(REVIEWER, "判定: LGTM"))
    ignore(rig.review())
    rig.head.val = HEAD_2
    let done = rig.review()
    assert_eq(show(field(done, "verdict")), "\"LGTM\"")
    assert_eq(show(field(done, "base")), "\"\{BASE}\"")
    assert_eq(show(field(done, "head")), "\"\{HEAD_2}\"")
    assert_eq(rig.args(2), [
      "exec",
      "resume",
      REVIEWER,
      "--json",
      "-c",
      "sandbox_mode=\"read-only\"",
      "-",
    ])
    assert_eq(@text.js_trim(rig.recorded("cwd", 2)), rig.checkout)
    let saved = read_state("\{rig.state_dir("example")}/state.json")
    assert_eq(show(field(saved, "heads")), "[\"\{HEAD_1}\",\"\{HEAD_2}\"]")
  })
}

///|
async test "a model and thinking chosen for a resume are passed on" {
  with_rig("choose", rig => {
    rig.plan(1, out=events(REVIEWER, "判定: 修正必要"))
    rig.plan(2, out=events(REVIEWER, "判定: LGTM"))
    ignore(rig.review(extra=["--model", "m", "--thinking", "high"]))
    rig.head.val = HEAD_2
    ignore(rig.review(extra=["--model", "n", "--thinking", "low"]))
    assert_eq(rig.args(1)[6:10].iter().collect(), [
      "-m", "m", "-c", "model_reasoning_effort=\"high\"",
    ])
    assert_eq(rig.args(2)[6:].iter().collect(), [
      "-m", "n", "-c", "model_reasoning_effort=\"low\"", "-",
    ])
  })
}

///|
async test "a head already judged is not reviewed again, but one the reviewer could not judge is" {
  with_rig("judged", rig => {
    rig.plan(1, out=events(REVIEWER, "判定: 修正必要"))
    ignore(rig.review())
    assert_eq(
      rig.review_failure(),
      "head \{HEAD_1} was already reviewed by \{REVIEWER}; commit a fix before asking again",
    )
    assert_eq(rig.runs(), 1)
    let path = "\{rig.state_dir("example")}/state.json"
    let saved = read_state(path)
    for verdict in [Json::string("判定保留"), Json::null()] {
      if saved is Object(members) {
        members["verdict"] = verdict
        write_text(path, show(Json::object(members)))
      }
      rig.plan(rig.runs() + 1, out=events(REVIEWER, "判定: LGTM"))
      assert_eq(rig.review_failure(), "")
    }
    assert_eq(rig.runs(), 3)
  })
}

///|
async test "a session keeps its worker AI, and a changed base needs --update-base" {
  with_rig("kept", rig => {
    rig.plan(1, out=events(REVIEWER, "判定: 修正必要"))
    ignore(rig.review())
    rig.head.val = HEAD_2
    let mismatch = failure_of(() => {
      ignore(rig.review(request=",\"workerAI\":\"Codex\""))
    })
    assert_eq(mismatch, "review session must keep the original workerAI")
    assert_eq(rig.runs(), 1)
  })
}

///|
async test "a run that reviewed nothing leaves nothing pending, so the head is sent again" {
  with_rig("nothing", rig => {
    rig.plan(1, out=events(REVIEWER, "判定: LGTM"), exit=3, stderr="boom\n")
    assert_eq(rig.review_failure(), "codex did not review (exit 3): boom")
    assert_false(rig.pending_exists("example"))
    rig.plan(
      2,
      out="{\"type\":\"turn.failed\",\"error\":{\"message\":\"rate limited\"}}",
    )
    assert_eq(
      rig.review_failure(),
      "codex did not review (exit 0): rate limited",
    )
    assert_false(rig.pending_exists("example"))
    rig.plan(
      3,
      out="{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"x\"}}",
    )
    assert_eq(rig.review_failure(), "codex answered without naming its thread")
    assert_false(rig.pending_exists("example"))
    rig.plan(4, out=events(REVIEWER, "判定: LGTM"))
    assert_eq(rig.review_failure(), "")
    assert_eq(rig.runs(), 4)
  })
}

///|
async test "a Codex CLI that cannot start leaves nothing pending" {
  with_rig("missing", rig => {
    let message = rig.review_failure(env=[
      ("HARNEXUS_CODEX_BIN", "/absent/codex"),
    ])
    assert_true(message.has_prefix("/absent/codex did not finish: "))
    assert_false(rig.pending_exists("example"))
    assert_eq(rig.runs(), 0)
  })
}

///|
async test "a reviewer gone from the machine is forgotten and a new one is started" {
  with_rig("gone", rig => {
    rig.plan(1, out=events(REVIEWER, "判定: 修正必要"))
    ignore(rig.review())
    rig.head.val = HEAD_2
    rig.plan(
      2,
      exit=1,
      stderr="ERROR: no rollout found for thread id \{REVIEWER}\n",
    )
    assert_eq(
      rig.review_failure(),
      "reviewer \{REVIEWER} is gone from this machine; run review again to start a new reviewer",
    )
    assert_false(rig.pending_exists("example"))
    let saved = read_state("\{rig.state_dir("example")}/state.json")
    assert_eq(show(field(saved, "reviewer")), "null")
    assert_eq(show(field(saved, "heads")), "[\"\{HEAD_1}\"]")
    rig.plan(3, out=events(OTHER, "判定: LGTM"))
    let done = rig.review()
    assert_eq(show(field(done, "reviewer")), "\"\{OTHER}\"")
    assert_eq(rig.args(3)[1], "--json")
  })
}

///|
async test "a failure other than a missing record keeps the reviewer" {
  with_rig("kept-reviewer", rig => {
    rig.plan(1, out=events(REVIEWER, "判定: 修正必要"))
    ignore(rig.review())
    rig.head.val = HEAD_2
    rig.plan(2, exit=1, stderr="network down")
    assert_eq(
      rig.review_failure(),
      "codex did not review (exit 1): network down",
    )
    rig.plan(3, out=events(REVIEWER, "判定: LGTM"))
    ignore(rig.review())
    assert_eq(rig.args(3)[1], "resume")
  })
}

///|
async test "a run that was stopped holds the review until it is discarded" {
  with_rig("stopped", rig => {
    let limits = [
      ("HARNEXUS_REVIEW_TIMEOUT_MS", "300"),
      ("HARNEXUS_REVIEW_KILL_GRACE_MS", "300"),
    ]
    rig.plan(1, out=events(REVIEWER, "判定: LGTM"), sleep="5")
    let stopped = rig.review_failure(env=limits)
    assert_eq(
      stopped, "codex was stopped (timeout); its result is unknown, so it is not sent again on its own. Check the reviewer, then rerun with --recover discard to send the candidate again",
    )
    assert_true(rig.pending_exists("example"))
    let pending = read_state("\{rig.state_dir("example")}/pending.json")
    assert_eq(show(field(pending, "reviewer")), "null")
    assert_eq(show(field(pending, "head")), "\"\{HEAD_1}\"")
    assert_eq(
      rig.review_failure(),
      "the review of head \{HEAD_1} did not report back: its result is unknown, so it is not sent again on its own. Check the reviewer, then rerun with --recover discard to send the candidate again",
    )
    assert_eq(rig.runs(), 1)
    rig.plan(2, out=events(REVIEWER, "判定: LGTM"))
    let done = rig.review(extra=["--recover", "discard"])
    assert_eq(show(field(done, "verdict")), "\"LGTM\"")
    assert_eq(rig.runs(), 2)
    assert_false(rig.pending_exists("example"))
  })
}

///|
async test "a stopped run names the reviewer it had started or was resuming" {
  with_rig("stopped-named", rig => {
    let limits = [
      ("HARNEXUS_REVIEW_TIMEOUT_MS", "300"),
      ("HARNEXUS_REVIEW_KILL_GRACE_MS", "300"),
    ]
    rig.plan(1, out=events(REVIEWER, "判定: 修正必要"))
    ignore(rig.review())
    rig.head.val = HEAD_2
    rig.plan(2, out=events(OTHER, "x"), sleep="5")
    assert_true(
      rig
      .review_failure(env=limits)
      .has_prefix("codex was stopped (timeout) in reviewer \{REVIEWER}; "),
    )
    assert_eq(
      show(
        field(
          read_state("\{rig.state_dir("example")}/pending.json"),
          "reviewer",
        ),
      ),
      "\"\{REVIEWER}\"",
    )
  })
}

///|
async test "an answer that cannot be recorded keeps the review pending and is shown" {
  with_rig("unrecorded", rig => {
    rig.plan(1, out=events(REVIEWER, "判定: LGTM"))
    rig.unwritable.val = Some("state.json")
    let message = rig.review_failure()
    assert_eq(
      message,
      "cannot write \{rig.state_dir("example")}/state.json; reviewer \{REVIEWER} answered, but it was not recorded, its result is unknown, so it is not sent again on its own. Check the reviewer, then rerun with --recover discard to send the candidate again. Its answer:\n判定: LGTM",
    )
    assert_true(rig.pending_exists("example"))
    assert_false(@store.path_exists("\{rig.state_dir("example")}/state.json"))
    assert_false(@store.path_exists("\{rig.state_dir("example")}/lock.json"))
  })
}

///|
async test "a review whose pending record cannot be written does not run" {
  with_rig("unwritable-pending", rig => {
    rig.unwritable.val = Some("pending.json")
    assert_eq(
      rig.review_failure(),
      "cannot write \{rig.state_dir("example")}/pending.json",
    )
    assert_eq(rig.runs(), 0)
  })
}

///|
async test "--recover applies only to a pending review" {
  with_rig("recover", rig => {
    assert_eq(
      rig.review_failure(extra=["--recover", "discard"]),
      "--recover applies only when a review is pending",
    )
    assert_eq(rig.runs(), 0)
  })
}

///|
async test "a question goes to the task's reviewer and leaves the verdict and head alone" {
  with_rig("ask", rig => {
    let ask = "\{rig.root}/ask.md"
    write_text(ask, "B1 はまだ残っていますか")
    assert_eq(
      rig.review_failure(extra=["--ask", ask]),
      "this task has no reviewer yet; run review first",
    )
    rig.plan(1, out=events(REVIEWER, "判定: 修正必要"))
    ignore(rig.review())
    let before = @store.read_text_if_exists(
      "\{rig.state_dir("example")}/state.json",
    )
    rig.plan(
      2,
      out=events(REVIEWER, "B1 は残っています。\n判定: LGTM"),
    )
    let answer = rig.review(extra=["--ask", ask])
    assert_eq(show(field(answer, "kind")), "\"reply\"")
    assert_eq(show(field(answer, "head")), "\"\{HEAD_1}\"")
    assert_eq(show(field(answer, "reviewer")), "\"\{REVIEWER}\"")
    assert_eq(show(field(answer, "verdict")), "\"LGTM\"")
    assert_eq(
      show(field(answer, "answer")),
      "\"B1 は残っています。\\n判定: LGTM\"",
    )
    assert_true(show(field(answer, "askedAt")).length() > 10)
    assert_eq(rig.recorded("stdin", 2), "B1 はまだ残っていますか")
    assert_eq(rig.args(2), [
      "exec",
      "resume",
      REVIEWER,
      "--json",
      "-c",
      "sandbox_mode=\"read-only\"",
      "-",
    ])
    assert_eq(
      @store.read_text_if_exists("\{rig.state_dir("example")}/state.json"),
      before,
    )
    assert_false(rig.pending_exists("example"))
  })
}

///|
async test "a question that cannot be asked or answered says so" {
  with_rig("ask-fails", rig => {
    rig.plan(1, out=events(REVIEWER, "判定: 修正必要"))
    ignore(rig.review())
    let ask = "\{rig.root}/ask.md"
    write_text(ask, " \n")
    assert_eq(
      rig.review_failure(extra=["--ask", ask]),
      "the --ask file is empty",
    )
    assert_true(
      rig
      .review_failure(extra=["--ask", "\{rig.root}/absent.md"])
      .has_prefix("cannot read "),
    )
    write_text(ask, "質問")
    rig.plan(2, exit=2, stderr="  no model  ")
    assert_eq(
      rig.review_failure(extra=["--ask", ask]),
      "reviewer \{REVIEWER} did not answer (exit 2): no model",
    )
    rig.plan(
      3,
      out="{\"type\":\"turn.failed\",\"error\":{\"message\":\"overloaded\"}}",
    )
    assert_eq(
      rig.review_failure(extra=["--ask", ask]),
      "reviewer \{REVIEWER} did not answer (exit 0): overloaded",
    )
    rig.plan(4, out=events(REVIEWER, "x"), sleep="5")
    assert_eq(
      rig.review_failure(extra=["--ask", ask], env=[
        ("HARNEXUS_REVIEW_TIMEOUT_MS", "300"),
        ("HARNEXUS_REVIEW_KILL_GRACE_MS", "300"),
      ]),
      "codex was stopped (timeout) in reviewer \{REVIEWER}; it may have answered, so check before asking again",
    )
    assert_false(rig.pending_exists("example"))
  })
}

///|
async test "a session another run is using is refused, and a dead run's session is taken over" {
  with_rig("lock", rig => {
    let lock = "\{rig.state_dir("example")}/lock.json"
    write_text(
      lock,
      "{\"pid\":\{@store.current_pid()},\"token\":\"t\",\"startedAt\":\"x\"}",
    )
    assert_eq(
      rig.review_failure(),
      "another review (pid \{@store.current_pid()}) is using this session",
    )
    assert_true(@store.path_exists(lock))
    assert_eq(rig.runs(), 0)
    write_text(lock, "{\"pid\":2147483000,\"token\":\"t\",\"startedAt\":\"x\"}")
    rig.plan(1, out=events(REVIEWER, "判定: LGTM"))
    assert_eq(rig.review_failure(), "")
    assert_false(@store.path_exists(lock))
    assert_false(@store.path_exists("\{lock}.reap"))
  })
}

///|
async test "the worker's chat is the cloud session, or cloud without one" {
  with_rig("chat", rig => {
    rig.plan(1, out=events(REVIEWER, "判定: 修正必要"))
    ignore(rig.review(env=[("CLAUDE_CODE_SESSION_ID", "")]))
    assert_eq(rig.prompts[0].get("worker_chat_id"), Some("cloud"))
    rig.head.val = HEAD_2
    rig.plan(2, out=events(REVIEWER, "判定: LGTM"))
    ignore(rig.review(request=",\"workerChatId\":\"w9\""))
    assert_eq(rig.prompts[1].get("worker_chat_id"), Some("w9"))
  })
}

///|
async test "a worker chat ID of another type is shown as JS writes it and saved as it came" {
  with_rig("chat-types", rig => {
    let cases = [
      ("null", "null"),
      ("7", "7"),
      ("true", "true"),
      ("[1,null,\"a\"]", "1,,a"),
      ("{\"a\":1}", "[object Object]"),
      ("1.5", "1.5"),
    ]
    let mut run = 0
    for item in cases {
      let (written, shown) = item
      run += 1
      rig.plan(run, out=events(REVIEWER, "判定: LGTM"))
      ignore(rig.review(request=",\"workerChatId\":\{written}"))
      assert_eq(rig.prompts[run - 1].get("worker_chat_id"), Some(shown))
      let saved = read_state("\{rig.state_dir("example")}/state.json")
      assert_eq(show(field(field(saved, "candidate"), "workerChatId")), written)
      @store.remove_record("\{rig.state_dir("example")}/state.json")
    }
  })
}

///|
async test "the Codex settings of the environment are checked before the review is recorded" {
  with_rig("settings", rig => {
    assert_eq(
      rig.review_failure(env=[("HARNEXUS_CODEX_BIN", "codex")]),
      "HARNEXUS_CODEX_BIN must be an absolute path",
    )
    assert_eq(
      rig.review_failure(env=[("HARNEXUS_REVIEW_TIMEOUT_MS", "0")]),
      "HARNEXUS_REVIEW_TIMEOUT_MS must be a positive number of milliseconds",
    )
    assert_eq(
      rig.review_failure(env=[("HARNEXUS_REVIEW_KILL_GRACE_MS", "x")]),
      "HARNEXUS_REVIEW_KILL_GRACE_MS must be a positive number of milliseconds",
    )
    assert_false(rig.pending_exists("example"))
    assert_eq(rig.runs(), 0)
  })
}
