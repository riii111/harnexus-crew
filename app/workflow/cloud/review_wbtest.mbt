///|
async test "a review under another worker AI than the session's is refused without running the reviewer" {
  with_rig("kept", rig => {
    rig.start_review()
    rig.head.val = HEAD_2

    let mismatch = @apptestkit.failure_of(() => {
      ignore(rig.review(request=",\"workerAI\":\"Codex\""))
    })

    assert_eq(mismatch, "review session must keep the original workerAI")
    assert_eq(rig.count_runs(), 1)
  })
}

///|
async test "a run stopped while resuming names that reviewer in its failure" {
  with_rig("stopped-named", rig => {
    rig.start_review_stopped_on_resume()

    assert_eq(
      rig.review_failure(env=stop_quickly_limits),
      "codex was stopped (timeout) in reviewer \{REVIEWER}; its result is unknown, so it is not sent again on its own. Check the reviewer, then rerun with --recover discard to send the candidate again",
    )
  })
}

///|
async test "a run stopped while resuming leaves a pending record naming that reviewer" {
  with_rig("stopped-pending", rig => {
    rig.start_review_stopped_on_resume()

    ignore(rig.review_failure(env=stop_quickly_limits))

    assert_true(rig.pending_exists("example"))
    assert_eq(
      @jsonio.field(
        read_state("\{rig.state_dir("example")}/pending.json"),
        "reviewer",
      ),
      Json::string(REVIEWER),
    )
  })
}

///|
async test "an answer that cannot be recorded is shown with the recovery step" {
  with_rig("unrecorded", rig => {
    rig.plan(1, out=events(REVIEWER, "判定: LGTM"))
    rig.unwritable.val = Some("state.json")

    assert_eq(
      rig.review_failure(),
      "cannot write \{rig.state_dir("example")}/state.json; reviewer \{REVIEWER} answered, but it was not recorded, its result is unknown, so it is not sent again on its own. Check the reviewer, then rerun with --recover discard to send the candidate again. Its answer:\n判定: LGTM",
    )
  })
}

///|
async test "an answer that cannot be recorded leaves only the pending record" {
  with_rig("unrecorded-records", rig => {
    rig.plan(1, out=events(REVIEWER, "判定: LGTM"))
    rig.unwritable.val = Some("state.json")

    ignore(rig.review_failure())

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
    assert_eq(rig.count_runs(), 0)
  })
}

///|
async test "a question from an empty file is refused" {
  with_rig("ask-empty", rig => {
    rig.start_review()
    let ask = "\{rig.root}/ask.md"
    write_text(ask, " \n")

    assert_eq(
      rig.review_failure(extra=["--ask", ask]),
      "the --ask file is empty",
    )
  })
}

///|
async test "a question from a file that cannot be read is refused" {
  with_rig("ask-absent", rig => {
    rig.start_review()
    let absent = "\{rig.root}/absent.md"

    assert_eq(
      rig.review_failure(extra=["--ask", absent]),
      "cannot read \{absent} (ENOENT)",
    )
  })
}

///|
async test "a question the reviewer exits on is refused with its exit status and stderr" {
  with_rig("ask-exit", rig => {
    rig.start_review()
    let ask = "\{rig.root}/ask.md"
    write_text(ask, "質問")
    rig.plan(2, exit=2, stderr="  no model  ")

    assert_eq(
      rig.review_failure(extra=["--ask", ask]),
      "reviewer \{REVIEWER} did not answer (exit 2): no model",
    )
  })
}

///|
async test "a question whose turn fails is refused with the reason of the turn" {
  with_rig("ask-turn-failed", rig => {
    rig.start_review()
    let ask = "\{rig.root}/ask.md"
    write_text(ask, "質問")
    rig.plan(
      2,
      out="{\"type\":\"turn.failed\",\"error\":{\"message\":\"overloaded\"}}",
    )

    assert_eq(
      rig.review_failure(extra=["--ask", ask]),
      "reviewer \{REVIEWER} did not answer (exit 0): overloaded",
    )
  })
}

///|
async test "a question stopped by the deadline says the reviewer may have answered" {
  with_rig("ask-stopped", rig => {
    rig.start_review()
    let ask = "\{rig.root}/ask.md"
    write_text(ask, "質問")
    rig.plan(2, out=events(REVIEWER, "x"), sleep="5")

    assert_eq(
      rig.review_failure(extra=["--ask", ask], env=stop_quickly_limits),
      "codex was stopped (timeout) in reviewer \{REVIEWER}; it may have answered, so check before asking again",
    )
  })
}

///|
async test "a question stopped by the deadline leaves the session's records as they were" {
  with_rig("ask-stopped-records", rig => {
    rig.start_review()
    let ask = "\{rig.root}/ask.md"
    write_text(ask, "質問")
    rig.plan(2, out=events(REVIEWER, "x"), sleep="5")

    ignore(rig.review_failure(extra=["--ask", ask], env=stop_quickly_limits))

    assert_eq(
      @jsonio.field(
        read_state("\{rig.state_dir("example")}/state.json"),
        "reviewer",
      ),
      Json::string(REVIEWER),
    )
    assert_false(rig.pending_exists("example"))
  })
}

///|
let stop_quickly_limits : Array[(String, String)] = [
  ("HARNEXUS_REVIEW_TIMEOUT_MS", "300"),
  ("HARNEXUS_REVIEW_KILL_GRACE_MS", "300"),
]

///|
async fn Rig::start_review(self : Rig) -> Unit {
  self.plan(1, out=events(REVIEWER, "判定: 修正必要"))
  let started = self.review()
  assert_eq(@jsonio.as_text(@jsonio.field(started, "status")), "completed")
}

///|
async fn Rig::start_review_stopped_on_resume(self : Rig) -> Unit {
  self.start_review()
  self.head.val = HEAD_2
  self.plan(2, out=events(OTHER, "x"), sleep="5")
}
