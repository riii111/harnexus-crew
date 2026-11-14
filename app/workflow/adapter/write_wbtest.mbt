///|
fn write_sent_file(
  at : Place,
  review : @host.CloudReview,
  thread_id : String,
) -> Unit {
  guard review_json(review) is Object(members) else { return }
  members["sent"] = Json::boolean(true)
  members["threadId"] = str(thread_id)
  members["shownAt"] = str("2026-11-01T00:00:00.000Z")
  write_file("\{at.reviews}/\{review.key}.json", text_of(Json::object(members)))
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
fn opening_path(at : Place, reviewer : String) -> String {
  "\{at.observe}/opening/\{short_hash(reviewer)}.json"
}

///|
fn save_opening(at : Place, showing : Bool) -> Unit {
  write_file(
    opening_path(at, "R1"),
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
async test "a review is shown once when two adapters take it at the same time" {
  with_place("write-race", at => {
    @async.with_task_group(group => {
      write_chats_file(at, object([("R1", str("chat-r1"))]))
      let one = connect(at, group)
      let two = connect(at, group)
      one.start("write")
      two.start("write")
      let entry = {
        parent_thread_id: parent,
        session_id: Some(session),
        review: review_of_head("aaa1111"),
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
async test "a message in a reviewer's chat is sent to the session that ran the reviewer" {
  with_place("write-ask-sent", at => {
    @async.with_task_group(group => {
      write_chats_file(at, object([("R1", bound_chat("chat-r1"))]))
      let link = connect(at, group)
      link.start("write")

      link.say(turn_line("t1", "chat-r1", "R1", "input", text="B1 は？"))

      let asked = link.requests(op="cloud_send")
      assert_eq(asked.length(), 1)
      assert_eq(text_member(asked[0], "sessionId"), Some(session))
      assert_eq(
        text_member(asked[0], "text"),
        Some(@host.reviewer_ask("R1", "B1 は？")),
      )
      assert_eq(
        link.lines_of_type("turn_output").map(line => text_member(line, "text")),
        [Some(@host.REVIEW_ASK_SENT)],
      )
    })
  })
}

///|
async test "a message in a chat whose session is not recorded is answered as unrouted" {
  with_place("write-ask-unrouted", at => {
    @async.with_task_group(group => {
      write_chats_file(at, object([("R2", str("chat-r2"))]))
      let link = connect(at, group)
      link.start("write")

      link.say(turn_line("t2", "chat-r2", "R2", "input", text="hello"))

      assert_eq(
        link.lines_of_type("turn_output").map(line => text_member(line, "text")),
        [Some(@host.REVIEW_ASK_UNROUTED)],
      )
      assert_eq(link.requests(op="cloud_send").length(), 0)
    })
  })
}

///|
async test "a message sent from a reviewer's chat is kept in the chat's history after its review" {
  with_place("write-ask-history", at => {
    @async.with_task_group(group => {
      write_chats_file(at, object([("R1", bound_chat("chat-r1"))]))
      let review = review_of_head("aaa1111")
      write_sent_file(at, review, "chat-r1")
      let link = connect(at, group)
      link.start("write")
      link.say(turn_line("t1", "chat-r1", "R1", "input", text="B1 は？"))

      link.say([
        ("type", str("request")),
        ("id", str("h1")),
        ("op", str("history")),
        ("conversationId", str("R1")),
        ("threadId", str("chat-r1")),
      ])

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
          (Some("assistant"), Some(@host.review_text(review))),
          (Some("user"), Some("B1 は？")),
          (Some("assistant"), Some(@host.REVIEW_ASK_SENT)),
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
      write_chats_file(at, object([("R1", str("chat-r1"))]))
      let link = connect(at, group)
      link.start("write")
      link.say_records("linked", [])
      link.say_records("continued", judged("aaa1111"))
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
async test "reviews queued by two adapters at once are all shown and none is left pending" {
  with_place("write-queue", at => {
    @async.with_task_group(group => {
      write_chats_file(
        at,
        object([("R1", str("chat-r1")), ("R2", str("chat-r2"))]),
      )
      let one = connect(at, group)
      let two = connect(at, group)
      one.start("write")
      two.start("write")
      one.say_records("linked", [], session_id="session_A")
      two.say_records("linked", [], session_id="session_B")
      let first = group.spawn(() => {
        one.say_records("continued", judged("aaa1111"), session_id="session_A")
      })
      let second = group.spawn(() => {
        two.say_records(
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
      assert_eq(read_pending_keys(one), [])
    })
  })
}

///|
async test "a binding only the bridge kept is recorded in the chats file" {
  with_place("write-bound-recorded", at => {
    @async.with_task_group(group => {
      let link = connect(at, group)
      link.say(hello_line("write"))

      link.say(ready_line([binding("R1", "chat-r1")]))

      assert_eq(
        text_of(read_json_file("\{at.reviews}/chats.json")),
        "{\"R1\":{\"threadId\":\"chat-r1\",\"session\":null}}",
      )
    })
  })
}

///|
async test "the next review is posted to a chat only the bridge kept, without creating another" {
  with_place("write-bound-first", at => {
    @async.with_task_group(group => {
      let link = connect(at, group)
      link.say(hello_line("write"))
      link.say(ready_line([binding("R1", "chat-r1")]))
      link.say_records("linked", [])

      link.say_records("continued", judged("aaa1111"))

      assert_eq(link.texts("post"), [
        @host.review_text(review_of_head("aaa1111")),
      ])
      assert_eq(link.requests(op="create_conversation").length(), 0)
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
      link.say_records("linked", [])
      link.say_records("continued", two_reviews())
      let posts_before_turn = link.requests(op="post").length()
      link.say(bound_line("R1", "chat-r1"))
      link.say(turn_line("t1", "chat-r1", "R1", "opened"))
      @async.sleep(20)
      assert_eq(link.requests(op="create_conversation").length(), 1)
      assert_eq(posts_before_turn, 0)
      assert_eq(
        text_member(link.lines_of_type("turn_output")[0], "text"),
        Some(@host.review_text(first)),
      )
      assert_eq(link.texts("post"), [@host.review_text(second)])
      assert_eq(read_pending_keys(link), [])
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
      before.say_records("linked", [])
      before.say_records("continued", two_reviews())
      let after = connect(at, group, answer=_ => done_with_chat("chat-r1"))
      after.say(hello_line("write"))
      after.say(ready_line([binding("R1", "chat-r1")]))
      assert_eq(after.requests(op="create_conversation").length(), 0)
      assert_eq(after.texts("post"), [
        @host.review_text(first),
        @host.review_text(second),
      ])
      assert_eq(read_pending_keys(after), [])
    })
  })
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
      assert_eq(@store.path_exists(opening_path(at, "R1")), false)
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
      let noted = link.logs.filter(entry => {
        text_member(entry, "step") == Some("opening_maybe_shown")
      })
      assert_eq(noted.length(), 1)
      assert_eq(text_member(noted[0], "reviewer"), Some("R1"))
      assert_eq(text_member(noted[0], "key"), Some("k1"))
      assert_eq(@store.path_exists(opening_path(at, "R1")), false)
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
      let kept = read_json_file(opening_path(at, "R1"))
      assert_eq(field(kept, "showing"), Some(Json::boolean(false)))
    })
  })
}

///|
/// The result of a `list_projects` request that names the review home.
fn projects_answer(at : Place) -> Json {
  let listing = object([
    (
      "projects",
      Json::array([
        object([
          ("projectId", str("review-home")),
          ("path", str(at.review_home)),
        ]),
      ]),
    ),
  ])
  object([
    ("outcome", str("done")),
    (
      "result",
      object([
        (
          "content",
          Json::array([
            object([("type", str("text")), ("text", str(text_of(listing)))]),
          ]),
        ),
      ]),
    ),
  ])
}

///|
fn done_with_chat(thread_id : String) -> Json {
  object([("outcome", str("done")), ("threadId", str(thread_id))])
}

///|
fn outcome_answer(outcome : String, reason~ : String? = None) -> Json {
  match reason {
    Some(reason) => object([("outcome", str(outcome)), ("reason", str(reason))])
    None => object([("outcome", str(outcome))])
  }
}
