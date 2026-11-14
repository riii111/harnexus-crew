///|
fn read_position_file(at : Place) -> Json {
  read_json_file("\{at.observe}/sessions/\{session}.json")
}

///|
async test "only the reviews after the link are taken, and each event is confirmed once its position is kept" {
  with_place("position-basic", at => {
    @async.with_task_group(group => {
      let link = connect(at, group)
      link.start("write")
      let before = [prompt("p0", "start"), ..judged("aaa1111")]
      link.records("linked", before, linked_at="u-t-aaa1111-R1")
      link.records(
        "continued",
        [..before, ..judged("bbb2222")],
        shown_before="u-t-aaa1111-R1",
      )
      assert_eq(link.lines_of_type("observed").map(text_of), [
        "{\"v\":1,\"type\":\"observed\",\"eventId\":\"e1\"}", "{\"v\":1,\"type\":\"observed\",\"eventId\":\"e2\"}",
      ])
      assert_eq(read_pending_keys(link), [review_of_head("bbb2222").key])
    })
  })
}

///|
async test "a session first seen continuing is measured from what the app was last shown, and that base is marked estimated" {
  with_place("position-estimated", at => {
    @async.with_task_group(group => {
      let link = connect(at, group)
      link.start("write")
      link.records("continued", two_reviews(), shown_before="u-t-aaa1111-R1")
      assert_eq(read_pending_keys(link), [review_of_head("bbb2222").key])
      let baseline = field(read_position_file(at), "baseline").unwrap()
      assert_eq(text_member(baseline, "uuid"), Some("u-t-aaa1111-R1"))
      assert_eq(field(baseline, "estimated"), Some(Json::boolean(true)))
    })
  })
}

///|
async test "a base the records no longer hold leaves every review in them out" {
  with_place("position-missing-base", at => {
    @async.with_task_group(group => {
      let link = connect(at, group)
      link.start("write")
      link.records("continued", judged("aaa1111"), shown_before="u-gone")
      assert_eq(read_pending_keys(link), [])
      let position = read_position_file(at)
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
  with_place("position-restart", at => {
    @async.with_task_group(group => {
      let first = connect(at, group)
      first.start("write")
      let linked = judged("aaa1111")
      first.records("linked", linked, linked_at="u-t-aaa1111-R1")
      let second = connect(at, group)
      second.start("write")
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
      assert_eq(read_pending_keys(second), [
        review_of_head("bbb2222").key,
        review_of_head("ccc3333").key,
      ])
      let position = read_position_file(at)
      assert_eq(field(position, "cursor"), Some(str("u-t-ccc3333-R1")))
    })
  })
}

///|
async test "a cursor whose record is gone reads the records again, and no review is taken again" {
  with_place("position-gap", at => {
    @async.with_task_group(group => {
      let link = connect(at, group)
      link.start("write")
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
      assert_eq(read_pending_keys(link), [review_of_head("aaa1111").key])
    })
  })
}

///|
async test "the position moves only once a review is queued, so a review that could not be queued is taken when the records come again" {
  with_place("position-queue-fails", at => {
    @async.with_task_group(group => {
      let link = connect(at, group)
      link.start("write")
      link.records("linked", [])
      // The list the first event left as a file becomes a directory, which cannot be read or written.
      remove_tree("\{at.observe}/pending.json")
      @store.prepare_directory("\{at.observe}/pending.json")
      link.records("continued", judged("aaa1111"))
      let confirmed_while_failing = link.lines_of_type("observed").length()
      remove_tree("\{at.observe}/pending.json")
      link.records("continued", judged("aaa1111"))
      assert_eq(confirmed_while_failing, 1)
      assert_eq(
        link.lines_of_type("observed").map(line => text_member(line, "eventId")),
        [Some("e1"), Some("e3")],
      )
      assert_eq(read_pending_keys(link), [review_of_head("aaa1111").key])
      assert_eq(
        link.logs
        .filter(entry => {
          text_member(entry, "step") == Some("pending_unwritable")
        })
        .length(),
        1,
      )
    })
  })
}

///|
async test "a session id that is not an id is logged and nothing is confirmed" {
  with_place("position-bad-session", at => {
    @async.with_task_group(group => {
      let link = connect(at, group)
      link.start("write")
      link.records("linked", [], session_id="../escape")
      assert_eq(link.lines_of_type("observed").length(), 0)
      assert_eq(link.logs.map(entry => text_member(entry, "step")), [
        Some("position_unreadable"),
      ])
      assert_eq(list_names("\{at.observe}/sessions"), [])
    })
  })
}
