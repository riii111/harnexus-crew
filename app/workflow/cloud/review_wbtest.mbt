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
        @jsonio.field(
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
