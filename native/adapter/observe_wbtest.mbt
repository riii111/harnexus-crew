///|
async test "an observing adapter journals only the reviews after the link, writes nothing, and confirms each event once its position is kept" {
  with_place("observe-basic", at => {
    @async.with_task_group(group => {
      let link = connect(at, group)
      link.start("observe")
      let before = [prompt("p0", "start"), ..judged("aaa1111")]
      link.records("linked", before, linked_at="u-t-aaa1111-R1")
      link.records(
        "continued",
        [..before, ..judged("bbb2222")],
        shown_before="u-t-aaa1111-R1",
      )
      assert_eq(
        text_of(link.lines_of_type("hello")[0]),
        "{\"v\":1,\"type\":\"hello\",\"adapterId\":\"taskctl\",\"bindings\":[]}",
      )
      assert_eq(link.requests().length(), 0)
      assert_eq(link.lines_of_type("observed").map(text_of), [
        "{\"v\":1,\"type\":\"observed\",\"eventId\":\"e1\"}", "{\"v\":1,\"type\":\"observed\",\"eventId\":\"e2\"}",
      ])
      assert_eq(heads_of(journal_of_kind(at, "observed_review")), ["bbb2222"])
      assert_eq(names_in(at.reviews), [])
    })
  })
}

///|
async test "a session first seen continuing is measured from what the app was last shown, and that base is marked estimated" {
  with_place("observe-estimated", at => {
    @async.with_task_group(group => {
      let link = connect(at, group)
      link.start("observe")
      link.records("continued", two_reviews(), shown_before="u-t-aaa1111-R1")
      let estimated = journal_of_kind(at, "baseline_estimated")
      assert_eq(estimated.length(), 1)
      assert_eq(text_member(estimated[0], "sessionId"), Some(session))
      assert_eq(
        text_member(estimated[0], "shownBefore"),
        Some("u-t-aaa1111-R1"),
      )
      assert_eq(heads_of(journal_of_kind(at, "observed_review")), ["bbb2222"])
      let position = read_json_file("\{at.observe}/sessions/\{session}.json")
      let baseline = field(position, "baseline").unwrap()
      assert_eq(text_member(baseline, "uuid"), Some("u-t-aaa1111-R1"))
      assert_eq(field(baseline, "estimated"), Some(Json::boolean(true)))
    })
  })
}

///|
async test "a base the records no longer hold leaves every review in them out and is journaled" {
  with_place("observe-missing-base", at => {
    @async.with_task_group(group => {
      let link = connect(at, group)
      link.start("observe")
      link.records("continued", judged("aaa1111"), shown_before="u-gone")
      assert_eq(journal_of_kind(at, "baseline_missing").length(), 1)
      assert_eq(journal_of_kind(at, "observed_review").length(), 0)
      let position = read_json_file("\{at.observe}/sessions/\{session}.json")
      assert_eq(field(position, "cursor"), Some(str("u-t-aaa1111-R1")))
      assert_eq(
        field(position, "excluded"),
        Some(Json::array([str(review_of_head("aaa1111").key)])),
      )
    })
  })
}

///|
async test "a review made while the adapter was stopped is taken once after it restarts" {
  with_place("observe-restart", at => {
    @async.with_task_group(group => {
      let first = connect(at, group)
      first.start("observe")
      let linked = judged("aaa1111")
      first.records("linked", linked, linked_at="u-t-aaa1111-R1")
      let second = connect(at, group)
      second.start("observe")
      let later = [..linked, ..judged("bbb2222")]
      second.records("continued", later, shown_before="u-t-aaa1111-R1")
      second.records("continued", later, shown_before="u-t-aaa1111-R1")
      // Records cut to the newest still hold the cursor, so only the review after it is taken.
      let newest = [
        ..judged("aaa1111"),
        ..judged("bbb2222"),
        ..judged("ccc3333"),
      ]
      second.records("continued", newest[2:].to_owned())
      assert_eq(heads_of(journal_of_kind(at, "observed_review")), [
        "bbb2222", "ccc3333",
      ])
      assert_eq(journal_of_kind(at, "cursor_missing").length(), 0)
      let position = read_json_file("\{at.observe}/sessions/\{session}.json")
      assert_eq(field(position, "cursor"), Some(str("u-t-ccc3333-R1")))
    })
  })
}

///|
async test "a cursor whose record is gone is recorded as a gap, and no review is taken again" {
  with_place("observe-gap", at => {
    @async.with_task_group(group => {
      let link = connect(at, group)
      link.start("observe")
      link.records("linked", [])
      link.records("continued", [prompt("p1", "x"), ..judged("aaa1111")])
      // The same review read again under records of other ids, as when the session's earlier records are gone.
      let reread = ran(
        "other",
        text_of(
          object([
            ("status", str("completed")),
            ("head", str("aaa1111")),
            ("reviewer", str("R1")),
            ("answer", str("判定: LGTM aaa1111")),
            ("verdict", str("LGTM")),
            ("taskId", str("harnexus-1")),
          ]),
        ),
      )
      link.records("continued", [..reread, prompt("p2", "y")])
      let gaps = journal_of_kind(at, "cursor_missing")
      assert_eq(gaps.length(), 1)
      assert_eq(text_member(gaps[0], "cursor"), Some("u-t-aaa1111-R1"))
      assert_eq(journal_of_kind(at, "observed_review").length(), 1)
      let position = read_json_file("\{at.observe}/sessions/\{session}.json")
      let recorded = field(position, "gaps").unwrap()
      guard recorded is Array(items) else { abort("gaps is not a list") }
      assert_eq(items.length(), 1)
      assert_eq(text_member(items[0], "cursor"), Some("u-t-aaa1111-R1"))
    })
  })
}

///|
async test "the reviews harnexus left unsent are journaled, and turns are refused" {
  with_place("observe-legacy", at => {
    @async.with_task_group(group => {
      let link = connect(at, group)
      link.start("observe")
      let review = review_of_head("aaa1111")
      link.say([
        ("type", str("event")),
        ("event", str("migration_unsent_reviews")),
        (
          "entries",
          Json::array([
            object([
              ("parentThreadId", str(parent)),
              ("review", review_json(review)),
            ]),
          ]),
        ),
      ])
      link.say(turn_line("t1", "x", "R1", "input", text="hi"))
      let unsent = journal_of_kind(at, "legacy_unsent")
      assert_eq(unsent.length(), 1)
      assert_eq(text_member(unsent[0], "parentThreadId"), Some(parent))
      let ended = link.lines_of_type("turn_end")
      assert_eq(ended.length(), 1)
      assert_eq(text_member(ended[0], "status"), Some("failed"))
      assert_eq(link.requests().length(), 0)
    })
  })
}

///|
async test "the position moves only once a review is journaled, so a review that could not be journaled is taken when the records come again" {
  with_place("observe-journal-fails", at => {
    @async.with_task_group(group => {
      let link = connect(at, group)
      link.start("observe")
      link.records("linked", [])
      @store.prepare_directory("\{at.observe}/journal.jsonl")
      link.records("continued", judged("aaa1111"))
      let confirmed_while_failing = link.lines_of_type("observed").length()
      remove_tree("\{at.observe}/journal.jsonl")
      link.records("continued", judged("aaa1111"))
      assert_eq(confirmed_while_failing, 1)
      assert_eq(
        link.lines_of_type("observed").map(line => text_member(line, "eventId")),
        [Some("e1"), Some("e3")],
      )
      assert_eq(journal_of_kind(at, "observed_review").length(), 1)
      assert_eq(
        link.logs
        .filter(entry => {
          text_member(entry, "step") == Some("journal_unwritable")
        })
        .length(),
        1,
      )
    })
  })
}

///|
async test "a session id that is not an id is logged and nothing is confirmed" {
  with_place("observe-bad-session", at => {
    @async.with_task_group(group => {
      let link = connect(at, group)
      link.start("observe")
      link.records("linked", [], session_id="../escape")
      assert_eq(link.lines_of_type("observed").length(), 0)
      assert_eq(link.logs.map(entry => text_member(entry, "step")), [
        Some("position_unreadable"),
      ])
      assert_eq(names_in(at.observe), [])
    })
  })
}

///|
async test "an event is confirmed to the bridge only once its position is kept" {
  with_place("observe-position-unwritable", at => {
    @async.with_task_group(group => {
      let link = connect(at, group)
      link.start("observe")
      let sessions = "\{at.observe}/sessions"
      @store.prepare_directory(sessions)
      ignore(
        @process.run_command("chmod", ["555", sessions], {
          "PATH": "/usr/bin:/bin",
        }),
      )
      link.records("linked", [])
      let confirmed_while_failing = link.lines_of_type("observed").length()
      ignore(
        @process.run_command("chmod", ["755", sessions], {
          "PATH": "/usr/bin:/bin",
        }),
      )
      link.records("linked", [])
      assert_eq(confirmed_while_failing, 0)
      assert_eq(
        link.lines_of_type("observed").map(line => text_member(line, "eventId")),
        [Some("e2")],
      )
    })
  })
}
