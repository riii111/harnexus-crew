///|
fn chats_file(at : Place, chats : Json) -> Unit {
  write_file("\{at.reviews}/chats.json", text_of(chats))
}

///|
fn sent_file(at : Place, review : @app.CloudReview, thread_id : String) -> Unit {
  guard review_json(review) is Object(members) else { return }
  members["sent"] = Json::boolean(true)
  members["threadId"] = str(thread_id)
  members["shownAt"] = str("2026-11-01T00:00:00.000Z")
  write_file("\{at.reviews}/\{review.key}.json", text_of(Json::object(members)))
}

///|
fn bound_chat(thread_id : String) -> Json {
  object([("threadId", str(thread_id)), ("session", str(session))])
}

///|
fn hello_line(mode : String) -> Array[(String, Json)] {
  [
    ("type", str("hello")),
    ("bridgeId", str("b1")),
    ("adapterId", str("taskctl")),
    ("mode", str(mode)),
    ("versions", Json::array([Json::number(1.0)])),
  ]
}

///|
fn binding(reviewer : String, thread_id : String) -> Json {
  object([("conversationId", str(reviewer)), ("threadId", str(thread_id))])
}

///|
fn bound_line(reviewer : String, thread_id : String) -> Array[(String, Json)] {
  [
    ("type", str("event")),
    ("event", str("conversation_bound")),
    ("conversationId", str(reviewer)),
    ("threadId", str(thread_id)),
  ]
}

///|
fn turn_lines(link : Link, turn_id : String) -> Array[Json] {
  link.sent.filter(line => text_member(line, "turnId") == Some(turn_id))
}

///|
fn turn_output(turn_id : String, text : String) -> String {
  text_of(
    object([
      ("v", Json::number(1.0)),
      ("type", str("turn_output")),
      ("turnId", str(turn_id)),
      ("text", str(text)),
      ("phase", str("final")),
    ]),
  )
}

///|
fn completed(turn_id : String) -> String {
  "{\"v\":1,\"type\":\"turn_end\",\"turnId\":\"\{turn_id}\",\"status\":\"completed\"}"
}

///|
async test "a writing adapter declares the old reviewer chats, posts a review to its reviewer's chat, and opens a chat for a new reviewer" {
  with_place("write-basic", at => {
    @async.with_task_group(group => {
      chats_file(at, object([("R1", bound_chat("chat-r1"))]))
      let link = connect(at, group, answer=request => {
        match text_member(request, "op") {
          Some("list_projects") => projects_answer(at)
          Some("create_conversation") => done_with_chat("chat-r2")
          _ => done_with_chat("chat-r1")
        }
      })
      link.start("write")
      let records = [..judged("aaa1111"), ..judged("bbb2222", reviewer="R2")]
      link.records("linked", [])
      link.records("continued", records)
      link.say(turn_line("t1", "chat-r2", "R2", "opened"))
      let r1 = review_of_head("aaa1111")
      let r2 = review_of_head("bbb2222", reviewer="R2")
      assert_eq(
        field(link.lines_of_type("hello")[0], "bindings").map(text_of),
        Some("[{\"conversationId\":\"R1\",\"threadId\":\"chat-r1\"}]"),
      )
      assert_eq(link.texts("post"), [@app.review_text(r1)])
      let created = link.requests(op="create_conversation")
      assert_eq(created.length(), 1)
      assert_eq(
        text_of(created[0]),
        "{\"v\":1,\"type\":\"request\",\"id\":\"harnexus-crew-3\",\"op\":\"create_conversation\",\"conversationId\":\"R2\",\"callerThreadId\":\"parent-chat\",\"arguments\":{\"target\":{\"type\":\"project\",\"projectId\":\"review-home\",\"environment\":{\"type\":\"local\"}},\"title\":\"☁️ Review｜harnexus-1\",\"model\":\"claude-sonnet-5-5\"}}",
      )
      assert_eq(turn_lines(link, "t1").map(text_of), [
        turn_output("t1", @app.review_text(r2)),
        completed("t1"),
      ])
      assert_eq(
        text_of(read_json_file("\{at.reviews}/chats.json")),
        "{\"R1\":{\"threadId\":\"chat-r1\",\"session\":\"session_01AbC\"},\"R2\":{\"threadId\":\"chat-r2\",\"session\":\"session_01AbC\"}}",
      )
      for review in [r1, r2] {
        let kept = read_json_file("\{at.reviews}/\{review.key}.json")
        assert_eq(field(kept, "sent"), Some(Json::boolean(true)))
      }
      assert_eq(pending_keys(link), [])
    })
  })
}

///|
async test "a review the bridge surely did not show waits for the next try, and an unknown send counts as shown" {
  with_place("write-outcomes", at => {
    @async.with_task_group(group => {
      chats_file(at, object([("R1", str("chat-r1"))]))
      let outcomes = [
        outcome_answer("not_sent", reason=Some("busy")),
        outcome_answer("unknown", reason=Some("busy")),
      ]
      let link = connect(at, group, answer=_ => {
        if outcomes.length() > 0 {
          outcomes.remove(0)
        } else {
          done_answer()
        }
      })
      link.start("write")
      let review = review_of_head("aaa1111")
      link.records("linked", [])
      link.records("continued", judged("aaa1111"))
      let waiting = pending_keys(link)
      let reserved_after_refusal = names_in(at.reviews).contains(
        "\{review.key}.reserved",
      )
      link.records("continued", judged("aaa1111"))
      link.records("continued", judged("aaa1111"))
      assert_eq(waiting, [review.key])
      assert_eq(reserved_after_refusal, false)
      assert_eq(link.requests(op="post").length(), 2)
      let kept = read_json_file("\{at.reviews}/\{review.key}.json")
      assert_eq(field(kept, "sent"), Some(Json::boolean(true)))
      assert_eq(text_member(kept, "threadId"), Some("chat-r1"))
    })
  })
}

///|
async test "nothing is sent for a review harnexus already sent or another adapter reserved" {
  with_place("write-skips", at => {
    @async.with_task_group(group => {
      let sent = review_of_head("aaa1111")
      let reserved = review_of_head("bbb2222")
      chats_file(at, object([("R1", str("chat-r1"))]))
      sent_file(at, sent, "chat-r1")
      write_file("\{at.reviews}/\{reserved.key}.reserved", "{}")
      let link = connect(at, group)
      link.start("write")
      link.records("linked", [])
      link.records("continued", two_reviews())
      assert_eq(link.requests(op="post").length(), 0)
      assert_eq(pending_keys(link), [])
    })
  })
}

///|
async test "a review is shown once when two adapters take it at the same time" {
  with_place("write-race", at => {
    @async.with_task_group(group => {
      chats_file(at, object([("R1", str("chat-r1"))]))
      let one = connect(at, group)
      let two = connect(at, group)
      one.start("write")
      two.start("write")
      let entry = {
        parent_thread_id: parent,
        session_id: Some(session),
        review: review_of_head("aaa1111"),
        raw: None,
      }
      one.adapter.deps.observations.keep_pending([entry]) catch {
        failed => abort(failed.message())
      }
      let first = group.spawn(() => one.say(ready_line([])))
      let second = group.spawn(() => two.say(ready_line([])))
      first.wait()
      second.wait()
      assert_eq(
        one.requests(op="post").length() + two.requests(op="post").length(),
        1,
      )
    })
  })
}

///|
async test "a message in a reviewer's chat goes to the session that ran the reviewer and is kept for the chat's history" {
  with_place("write-ask", at => {
    @async.with_task_group(group => {
      chats_file(
        at,
        object([("R1", bound_chat("chat-r1")), ("R2", str("chat-r2"))]),
      )
      let review = review_of_head("aaa1111")
      sent_file(at, review, "chat-r1")
      let link = connect(at, group)
      link.start("write")
      link.say(turn_line("t1", "chat-r1", "R1", "input", text="B1 は？"))
      link.say(turn_line("t2", "chat-r2", "R2", "input", text="hello"))
      link.say([
        ("type", str("request")),
        ("id", str("h1")),
        ("op", str("history")),
        ("conversationId", str("R1")),
        ("threadId", str("chat-r1")),
      ])
      let asked = link.requests(op="cloud_send")
      assert_eq(asked.length(), 1)
      assert_eq(text_member(asked[0], "sessionId"), Some(session))
      assert_eq(
        text_member(asked[0], "text"),
        Some(@app.reviewer_ask("R1", "B1 は？")),
      )
      assert_eq(
        link.lines_of_type("turn_output").map(line => text_member(line, "text")),
        [Some(@app.REVIEW_ASK_SENT), Some(@app.REVIEW_ASK_UNROUTED)],
      )
      let history = link.sent.filter(line => {
          text_member(line, "type") == Some("response") &&
          text_member(line, "id") == Some("h1")
        })[0]
      guard field(history, "entries") is Some(Array(entries)) else {
        abort("no entries")
      }
      assert_eq(
        entries.map(entry => {
          (text_member(entry, "role"), text_member(entry, "text"))
        }),
        [
          (Some("assistant"), Some(@app.review_text(review))),
          (Some("user"), Some("B1 は？")),
          (Some("assistant"), Some(@app.REVIEW_ASK_SENT)),
        ],
      )
      assert_eq(text_member(entries[0], "at"), Some("2026-11-01T00:00:00.000Z"))
    })
  })
}

///|
async test "the session that ran a review shown in a chat kept from before is recorded, so a message from the chat reaches it" {
  with_place("write-session", at => {
    @async.with_task_group(group => {
      chats_file(at, object([("R1", str("chat-r1"))]))
      let link = connect(at, group)
      link.start("write")
      link.records("linked", [])
      link.records("continued", judged("aaa1111"))
      link.say(turn_line("t1", "chat-r1", "R1", "input", text="B1 は？"))
      assert_eq(
        text_of(read_json_file("\{at.reviews}/chats.json")),
        "{\"R1\":{\"threadId\":\"chat-r1\",\"session\":\"session_01AbC\"}}",
      )
      let asked = link.requests(op="cloud_send")
      assert_eq(asked.length(), 1)
      assert_eq(text_member(asked[0], "sessionId"), Some(session))
    })
  })
}

///|
async test "the reviews two adapters queue at once are kept, and each is shown" {
  with_place("write-queue", at => {
    @async.with_task_group(group => {
      chats_file(at, object([("R1", str("chat-r1")), ("R2", str("chat-r2"))]))
      let one = connect(at, group)
      let two = connect(at, group)
      one.start("write")
      two.start("write")
      one.records("linked", [], session_id="session_A")
      two.records("linked", [], session_id="session_B")
      let first = group.spawn(() => {
        one.records("continued", judged("aaa1111"), session_id="session_A")
      })
      let second = group.spawn(() => {
        two.records(
          "continued",
          judged("bbb2222", reviewer="R2"),
          session_id="session_B",
        )
      })
      first.wait()
      second.wait()
      @async.sleep(20)
      let posted = [..one.requests(op="post"), ..two.requests(op="post")].map(line => {
        text_member(line, "conversationId").unwrap_or("")
      })
      posted.sort_by(String::lexical_compare)
      assert_eq(posted, ["R1", "R2"])
      assert_eq(pending_keys(one), [])
    })
  })
}

///|
async test "a review the bridge refused, such as for a binding conflict, waits until it can be shown" {
  with_place("write-refused", at => {
    @async.with_task_group(group => {
      chats_file(at, object([("R1", str("chat-r1"))]))
      let answers = [
        outcome_answer("rejected", reason=Some("binding_conflict")),
        outcome_answer("invalid"),
      ]
      let link = connect(at, group, answer=_ => {
        if answers.length() > 0 {
          answers.remove(0)
        } else {
          done_answer()
        }
      })
      link.start("write")
      let review = review_of_head("aaa1111")
      link.records("linked", [])
      link.records("continued", judged("aaa1111"))
      link.records("continued", judged("aaa1111"))
      let waiting = pending_keys(link)
      link.records("continued", judged("aaa1111"))
      assert_eq(waiting, [review.key])
      assert_eq(link.requests(op="post").length(), 3)
      assert_eq(pending_keys(link), [])
      let kept = read_json_file("\{at.reviews}/\{review.key}.json")
      assert_eq(field(kept, "sent"), Some(Json::boolean(true)))
    })
  })
}

///|
async test "a binding only the bridge kept is recorded, and the next review is posted to that chat" {
  with_place("write-bound-first", at => {
    @async.with_task_group(group => {
      let link = connect(at, group)
      link.say(hello_line("write"))
      link.say(ready_line([binding("R1", "chat-r1")]))
      link.records("linked", [])
      link.records("continued", judged("aaa1111"))
      assert_eq(
        text_of(read_json_file("\{at.reviews}/chats.json")),
        "{\"R1\":{\"threadId\":\"chat-r1\",\"session\":\"session_01AbC\"}}",
      )
      assert_eq(link.requests(op="post").length(), 1)
      assert_eq(link.requests(op="create_conversation").length(), 0)
    })
  })
}

///|
async test "a review is posted when a create answers with a conversation the bridge already shows" {
  with_place("write-existing", at => {
    @async.with_task_group(group => {
      let link = connect(at, group, answer=request => {
        match text_member(request, "op") {
          Some("list_projects") => projects_answer(at)
          Some("create_conversation") =>
            object([
              ("outcome", str("done")),
              ("threadId", str("chat-r1")),
              ("existing", Json::boolean(true)),
            ])
          _ => done_with_chat("chat-r1")
        }
      })
      link.start("write")
      let review = review_of_head("aaa1111")
      link.records("linked", [])
      link.records("continued", judged("aaa1111"))
      assert_eq(link.texts("post"), [@app.review_text(review)])
      let kept = read_json_file("\{at.reviews}/\{review.key}.json")
      assert_eq(field(kept, "sent"), Some(Json::boolean(true)))
      assert_eq(text_member(kept, "threadId"), Some("chat-r1"))
    })
  })
}

///|
async test "a chat whose create was unknown shows the review once its first turn arrives, and is not created again" {
  with_place("write-unknown-create", at => {
    @async.with_task_group(group => {
      let link = connect(at, group, answer=request => {
        if text_member(request, "op") == Some("list_projects") {
          projects_answer(at)
        } else {
          outcome_answer("unknown", reason=Some("pending_create"))
        }
      })
      link.start("write")
      let review = review_of_head("aaa1111")
      link.records("linked", [])
      link.records("continued", judged("aaa1111"))
      link.say(bound_line("R1", "chat-r1"))
      link.say(turn_line("t1", "chat-r1", "R1", "opened"))
      link.records("continued", judged("aaa1111"))
      assert_eq(link.requests(op="create_conversation").length(), 1)
      assert_eq(turn_lines(link, "t1").map(text_of), [
        turn_output("t1", @app.review_text(review)),
        completed("t1"),
      ])
      assert_eq(
        text_of(read_json_file("\{at.reviews}/chats.json")),
        "{\"R1\":{\"threadId\":\"chat-r1\",\"session\":\"session_01AbC\"}}",
      )
    })
  })
}

///|
async test "while a chat's first review waits for its first turn, a later review of the same reviewer waits too, and is posted after it" {
  with_place("write-later-reviews", at => {
    @async.with_task_group(group => {
      let link = connect(at, group, answer=request => {
        match text_member(request, "op") {
          Some("list_projects") => projects_answer(at)
          Some("create_conversation") =>
            outcome_answer("unknown", reason=Some("pending_create"))
          _ => done_with_chat("chat-r1")
        }
      })
      link.start("write")
      let first = review_of_head("aaa1111")
      let second = review_of_head("bbb2222")
      link.records("linked", [])
      link.records("continued", two_reviews())
      let posts_before_turn = link.requests(op="post").length()
      link.say(bound_line("R1", "chat-r1"))
      link.say(turn_line("t1", "chat-r1", "R1", "opened"))
      @async.sleep(20)
      assert_eq(link.requests(op="create_conversation").length(), 1)
      assert_eq(posts_before_turn, 0)
      assert_eq(
        text_member(link.lines_of_type("turn_output")[0], "text"),
        Some(@app.review_text(first)),
      )
      assert_eq(link.texts("post"), [@app.review_text(second)])
      assert_eq(pending_keys(link), [])
    })
  })
}

///|
async test "the first review is posted after a restart when the bridge bound its chat while the adapter was away, then the next" {
  with_place("write-restart", at => {
    @async.with_task_group(group => {
      let before = connect(at, group, answer=request => {
        if text_member(request, "op") == Some("list_projects") {
          projects_answer(at)
        } else {
          outcome_answer("unknown", reason=Some("pending_create"))
        }
      })
      before.start("write")
      let first = review_of_head("aaa1111")
      let second = review_of_head("bbb2222")
      before.records("linked", [])
      before.records("continued", two_reviews())
      let after = connect(at, group, answer=_ => done_with_chat("chat-r1"))
      after.say(hello_line("write"))
      after.say(ready_line([binding("R1", "chat-r1")]))
      assert_eq(after.requests(op="create_conversation").length(), 0)
      assert_eq(after.texts("post"), [
        @app.review_text(first),
        @app.review_text(second),
      ])
      assert_eq(pending_keys(after), [])
    })
  })
}

///|
fn opening_file(at : Place, reviewer : String) -> String {
  "\{at.observe}/opening/\{short_hash(reviewer)}.json"
}

///|
fn save_opening(at : Place, showing : Bool) -> Unit {
  write_file(
    opening_file(at, "R1"),
    text_of(
      object([
        ("key", str("k1")),
        ("text", str("first review")),
        ("sessionId", str(session)),
        ("showing", Json::boolean(showing)),
      ]),
    ),
  )
}

///|
async fn reconnect(link : Link) -> Unit {
  link.say(hello_line("write"))
  link.say(ready_line([binding("R1", "chat-r1")]))
}

///|
async test "a chat's first review is posted by one of two adapters reconnecting at once" {
  with_place("opening-race", at => {
    @async.with_task_group(group => {
      save_opening(at, false)
      let one = connect(at, group)
      let two = connect(at, group)
      let first = group.spawn(() => reconnect(one))
      let second = group.spawn(() => reconnect(two))
      first.wait()
      second.wait()
      assert_eq([..one.texts("post"), ..two.texts("post")], ["first review"])
      assert_eq(@store.path_exists(opening_file(at, "R1")), false)
    })
  })
}

///|
async test "a chat's first review is never posted again when an earlier adapter stopped after it may have shown it" {
  with_place("opening-maybe-shown", at => {
    @async.with_task_group(group => {
      save_opening(at, true)
      let link = connect(at, group)
      reconnect(link)
      assert_eq(link.requests(op="post").length(), 0)
      let noted = journal_of_kind(at, "opening_maybe_shown")
      assert_eq(noted.length(), 1)
      assert_eq(text_member(noted[0], "reviewer"), Some("R1"))
      assert_eq(text_member(noted[0], "key"), Some("k1"))
      assert_eq(@store.path_exists(opening_file(at, "R1")), false)
    })
  })
}

///|
async test "a chat's first review stays for the next connection when the bridge surely did not post it" {
  with_place("opening-not-sent", at => {
    @async.with_task_group(group => {
      save_opening(at, false)
      let link = connect(at, group, answer=_ => {
        outcome_answer("not_sent", reason=Some("busy"))
      })
      reconnect(link)
      assert_eq(link.requests(op="post").length(), 1)
      let kept = read_json_file(opening_file(at, "R1"))
      assert_eq(field(kept, "showing"), Some(Json::boolean(false)))
    })
  })
}

///|
async test "the journaled reviews nobody sent are handed over, and a writing adapter then shows them" {
  with_place("handover", at => {
    @async.with_task_group(group => {
      let sent_by_harnexus = review_of_head("aaa1111")
      let observed = review_of_head("bbb2222")
      let unsent = review_of_head("ccc3333")
      let watcher = connect(at, group)
      watcher.start("observe")
      watcher.records("linked", [])
      watcher.records("continued", two_reviews())
      watcher.say([
        ("type", str("event")),
        ("event", str("migration_unsent_reviews")),
        (
          "entries",
          Json::array([
            object([
              ("parentThreadId", str(parent)),
              ("review", review_json(unsent)),
            ]),
          ]),
        ),
      ])
      sent_file(at, sent_by_harnexus, "chat-r1")
      chats_file(at, object([("R1", bound_chat("chat-r1"))]))
      let deps = watcher.adapter.deps
      let handed = hand_over(deps.observations, deps.store, journal_lines(at)) catch {
        failed => abort(failed.message())
      }
      let again = hand_over(deps.observations, deps.store, journal_lines(at)) catch {
        failed => abort(failed.message())
      }
      let writer = connect(at, group)
      writer.start("write")
      assert_eq(text_of(handed), "{\"handedOver\":2,\"skipped\":1}")
      assert_eq(text_of(again), "{\"handedOver\":0,\"skipped\":1}")
      assert_eq(writer.texts("post"), [
        @app.review_text(observed),
        @app.review_text(unsent),
      ])
    })
  })
}
