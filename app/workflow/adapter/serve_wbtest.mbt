///|
/// Waits until the adapter has sent `count` requests, which a bridge that answers nothing leaves waiting.
async fn wait_for_requests(link : Link, count : Int32) -> Unit {
  for _ in 0..<400 {
    if link.requests().length() >= count {
      return
    }
    @async.sleep(5)
  }
  abort("only \{link.requests().length()} of \{count} requests were sent")
}

///|
fn response_line(id : String, outcome : String) -> String {
  text_of(
    object([
      ("v", Json::number(1.0)),
      ("type", str("response")),
      ("id", str(id)),
      ("outcome", str(outcome)),
    ]),
  )
}

///|
async test "a request still waiting when the bridge closes ends as unknown, and a later request is not sent" {
  with_place("serve-close-waiting", at => {
    @async.with_task_group(group => {
      write_file("\{at.reviews}/chats.json", "{\"R1\":\"chat-r1\"}")
      let link = connect(at, group, silent=true)
      link.start("write")
      link.records("linked", [])
      let review = review_of_head("aaa1111")
      let handling = group.spawn(() => {
        link.records("continued", judged("aaa1111"))
      })
      wait_for_requests(link, 1)
      link.adapter.close_input()
      handling.wait()
      let kept = read_json_file("\{at.reviews}/\{review.key}.json")
      assert_eq(field(kept, "sent"), Some(Json::boolean(true)))
      assert_eq(read_pending_keys(link), [])
      let later = link.adapter.request("post", [("text", str("late"))])
      assert_eq(later.outcome, "not_sent")
      assert_eq(later.reason(), Some("closed"))
      assert_eq(link.requests().length(), 1)
      assert_eq(link.adapter.unanswered.length(), 0)
    })
  })
}

///|
async test "a review whose chat could not be listed when the bridge closes waits for the next connection" {
  with_place("serve-close-listing", at => {
    @async.with_task_group(group => {
      let link = connect(at, group, silent=true)
      link.start("write")
      link.records("linked", [])
      let review = review_of_head("aaa1111")
      let handling = group.spawn(() => {
        link.records("continued", judged("aaa1111"))
      })
      wait_for_requests(link, 1)
      link.adapter.close_input()
      handling.wait()
      assert_eq(read_pending_keys(link), [review.key])
      assert_eq(
        list_names(at.reviews).contains("\{review.key}.reserved"),
        false,
      )
    })
  })
}

///|
async test "a question to a reviewer whose answer never comes ends the turn as failed when the bridge closes" {
  with_place("serve-close-ask", at => {
    @async.with_task_group(group => {
      write_file(
        "\{at.reviews}/chats.json",
        "{\"R1\":{\"threadId\":\"chat-r1\",\"session\":\"session_01AbC\"}}",
      )
      let link = connect(at, group, silent=true)
      link.start("write")
      let handling = group.spawn(() => {
        link.say(turn_line("t1", "chat-r1", "R1", "input", text="hello"))
      })
      wait_for_requests(link, 1)
      link.adapter.close_input()
      handling.wait()
      let ended = link.lines_of_type("turn_end")
      assert_eq(ended.length(), 1)
      assert_eq(text_member(ended[0], "status"), Some("failed"))
      assert_eq(
        text_member(ended[0], "message"),
        Some(@host.REVIEW_ASK_UNKNOWN),
      )
    })
  })
}

///|
async test "an answer reaches the request that asked, whatever the order they arrive in" {
  with_place("serve-answers", at => {
    @async.with_task_group(group => {
      let link = connect(at, group, silent=true)
      link.start("write")
      let outcomes : Array[String] = ["", "", ""]
      let tasks = []
      for index in 0..<3 {
        tasks.push(
          group.spawn(() => {
            outcomes[index] = link.adapter.request("post", [
                ("text", str("n\{index}")),
              ]).outcome
          }),
        )
      }
      wait_for_requests(link, 3)
      let ids = link
        .requests()
        .map(line => text_member(line, "id").unwrap_or(""))
      let texts = link
        .requests()
        .map(line => text_member(line, "text").unwrap_or(""))
      // The third request is answered first and the first last.
      for index in [2, 1, 0] {
        link.adapter.receive(
          response_line(ids[index], "answer-\{texts[index]}"),
        )
      }
      for task in tasks {
        task.wait()
      }
      assert_eq(outcomes, ["answer-n0", "answer-n1", "answer-n2"])
      assert_eq(link.adapter.unanswered.length(), 0)
    })
  })
}

///|
async test "a response nobody asked for is dropped without disturbing a request that waits" {
  with_place("serve-stray-response", at => {
    @async.with_task_group(group => {
      let link = connect(at, group, silent=true)
      link.start("write")
      let outcome = Ref("")
      let task = group.spawn(() => {
        outcome.val = link.adapter.request("post", [("text", str("x"))]).outcome
      })
      wait_for_requests(link, 1)
      link.adapter.receive(response_line("harnexus-crew-99", "done"))
      assert_eq(link.adapter.unanswered.length(), 1)
      link.adapter.receive(response_line("harnexus-crew-1", "done"))
      task.wait()
      assert_eq(outcome.val, "done")
    })
  })
}

///|
async test "a bridge in observe mode is refused: nothing is greeted, taken or sent, and turns fail" {
  with_place("serve-observe-refused", at => {
    @async.with_task_group(group => {
      let link = connect(at, group)
      link.start("observe")
      link.records("linked", [])
      link.records("continued", judged("aaa1111"))
      link.say(turn_line("t1", "x", "R1", "opened"))
      assert_eq(link.lines_of_type("hello").length(), 0)
      assert_eq(link.lines_of_type("observed").length(), 0)
      assert_eq(link.requests().length(), 0)
      let ended = link.lines_of_type("turn_end")
      assert_eq(ended.map(line => text_member(line, "status")), [Some("failed")])
      assert_eq(link.logs.map(entry => text_member(entry, "step")), [
        Some("mode_refused"),
      ])
      assert_eq(list_names(at.observe), [])
    })
  })
}

///|
async test "many round trips leave no descriptor, waiting request or lock behind" {
  with_place("serve-round-trips", at => {
    @async.with_task_group(group => {
      write_file("\{at.reviews}/chats.json", "{\"R1\":\"chat-r1\"}")
      let link = connect(at, group)
      link.start("write")
      link.records("linked", [])
      // A first round trip opens whatever the adapter keeps open for good.
      link.records("continued", judged("h000000"))
      let before = @testkit.open_fds()
      let rounds = 60
      for round in 1..<rounds {
        let head = "h\{round.to_string()}"
        link.records("continued", [..judged("h000000"), ..judged(head)])
      }
      assert_eq(@testkit.open_fds(), before)
      assert_eq(link.adapter.unanswered.length(), 0)
      assert_eq(link.requests(op="post").length(), rounds)
      assert_eq(read_pending_keys(link), [])
      assert_eq(list_names("\{at.observe}/locks"), [])
    })
  })
}

///|
async test "lines handled at the same time are written whole, one to a line" {
  with_place("serve-concurrent-lines", at => {
    @async.with_task_group(group => {
      let link = connect(at, group)
      link.start("write")
      let tasks = []
      for index in 0..<40 {
        tasks.push(
          group.spawn(() => {
            link.adapter.receive(
              text_of(
                object([
                  ("v", Json::number(1.0)),
                  ("type", str("request")),
                  ("id", str("h\{index}")),
                  ("op", str("history")),
                  ("threadId", str("chat-r1")),
                ]),
              ),
            )
          }),
        )
      }
      for task in tasks {
        task.wait()
      }
      let ids = link
        .lines_of_type("response")
        .map(line => text_member(line, "id"))
      assert_eq(ids.length(), 40)
      for index in 0..<40 {
        assert_eq(ids.contains(Some("h\{index}")), true)
      }
    })
  })
}
