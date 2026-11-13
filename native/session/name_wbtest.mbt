///|
async test "name links the PR first and renames only the thread of a launched worker" {
  with_rig("n-1", [@app.CallAnswer::new(Done, [])], rig => {
    ignore(
      {
        let launch = rig.context([])
        write_text(
          "\{rig.launch_dir()}/state.json",
          "{\"threadId\":\"w1\",\"request\":{\"taskId\":\"TR1\",\"displayName\":\"Named\"}}",
        )
        launch
      },
    )
    rig.linked.val = Some({
      "watched": Json::string("https://github.com/o/r/pull/3"),
      "warning": Json::string("nothing can send to w1"),
    })
    let shown = name_in(
      rig.context([]),
      name_args("https://github.com/o/r/pull/3"),
    )
    assert_eq(
      show(shown),
      "{\"threadId\":\"w1\",\"title\":\"Impl｜Named PR#3\",\"watched\":\"https://github.com/o/r/pull/3\",\"warning\":\"nothing can send to w1\"}",
    )
    assert_eq(rig.pr_wake_calls, [
      ["link", "https://github.com/o/r/pull/3", "--take-over"],
    ])
    let (caller, tool, args) = rig.calls[0]
    assert_eq((caller, tool), ("w1", "name_thread"))
    assert_eq(show(Json::object(args)), "{\"name\":\"Impl｜Named PR#3\"}")
  })
}

///|
async test "a rename the app did not apply leaves the PR watched and says so" {
  with_rig("n-2", [bridge_answer({ "outcome": "rejected", "error": "no" })], rig => {
    write_text(
      "\{rig.launch_dir()}/state.json",
      "{\"threadId\":\"w1\",\"request\":{\"taskId\":\"TR1\"}}",
    )
    rig.linked.val = Some({
      "watched": Json::string("https://github.com/o/r/pull/3"),
    })
    let shown = name_in(
      rig.context([]),
      name_args("https://github.com/o/r/pull/3"),
    )
    assert_eq(
      show(shown),
      "{\"threadId\":\"w1\",\"title\":null,\"watched\":\"https://github.com/o/r/pull/3\",\"renameError\":\"name_thread was not applied: {\\\"outcome\\\":\\\"rejected\\\",\\\"error\\\":\\\"no\\\"}\"}",
    )
  })
}

///|
async test "a PR that is not a GitHub PR URL is refused before the thread is renamed" {
  with_rig("n-3", [@app.CallAnswer::new(Done, [])], rig => {
    write_text(
      "\{rig.launch_dir()}/state.json",
      "{\"threadId\":\"w1\",\"request\":{\"taskId\":\"TR1\"}}",
    )
    for pr in ["3", "#3", "https://example.com/o/r/pull/3"] {
      assert_eq(
        failure_of(() => ignore(name_in(rig.context([]), name_args(pr)))),
        "\{pr} is not watched: the PR watch needs the URL https://github.com/<owner>/<repo>/pull/<number>",
      )
    }
    assert_eq(rig.pr_wake_calls.length(), 0)
    assert_eq(rig.calls.length(), 0)
  })
}

///|
async test "name leaves the title of a thread that no launch started and of a T3 Code thread" {
  with_rig("n-5", [], rig => {
    write_text(
      "\{rig.launch_dir()}/state.json",
      "{\"threadId\":\"w1\",\"request\":{\"taskId\":\"TR1\"}}",
    )
    rig.linked.val = Some({
      "watched": Json::string("https://github.com/o/r/pull/3"),
    })
    let t3 = name_in(
      rig.context([("T3CODE_THREAD_ID", "w1")]),
      name_args("https://github.com/o/r/pull/3"),
    )
    assert_eq(
      show(t3),
      "{\"threadId\":\"w1\",\"title\":null,\"watched\":\"https://github.com/o/r/pull/3\"}",
    )
    let other = name_in(
      rig.context([("CODEX_THREAD_ID", "someone-else")]),
      name_args("https://github.com/o/r/pull/3"),
    )
    assert_eq(
      show(other),
      "{\"threadId\":\"someone-else\",\"title\":null,\"watched\":\"https://github.com/o/r/pull/3\"}",
    )
    assert_eq(rig.calls.length(), 0)
  })
}

///|
async test "a failure of pr-wake fails name before anything is renamed" {
  with_rig("n-6", [], rig => {
    assert_eq(
      failure_of(() => {
        ignore(
          name_in(rig.context([]), name_args("https://github.com/o/r/pull/3")),
        )
      }),
      "pr-wake is not set up",
    )
    assert_eq(rig.calls.length(), 0)
  })
}

///|
async test "the launch of a thread is found among the launches by their state, skipping unreadable ones" {
  with_rig("n-7", [], rig => {
    let env = rig.env([])
    let launches = "\{rig.root}/state/harnexus-crew/launch"
    assert_eq(launch_of_thread(env, "w1").map(show), None)
    write_text("\{launches}/aaaa/state.json", "{")
    write_text(
      "\{launches}/bbbb/state.json",
      "{\"threadId\":\"w2\",\"request\":{\"taskId\":\"A\"}}",
    )
    write_text(
      "\{launches}/cccc/state.json",
      "{\"threadId\":\"w1\",\"request\":\"not an object\"}",
    )
    write_text(
      "\{launches}/dddd/state.json",
      "{\"threadId\":\"w1\",\"request\":{\"taskId\":\"D\"}}",
    )
    write_text(
      "\{launches}/eeee/state.json",
      "{\"threadId\":\"w1\",\"request\":{\"taskId\":\"E\"}}",
    )
    write_text("\{launches}/stray.json", "{}")
    assert_eq(launch_of_thread(env, "w1").map(show), Some("{\"taskId\":\"D\"}"))
    assert_eq(launch_of_thread(env, "w3").map(show), None)
  })
}

///|
test "the helpers read records as the TypeScript build does" {
  assert_false(truthy(Json::null()))
  assert_false(truthy(Json::boolean(false)))
  assert_false(truthy(Json::number(0.0)))
  assert_false(truthy(Json::string("")))
  assert_false(truthy(Json::array([])))
  assert_false(truthy(Json::object({})))
  assert_true(truthy(Json::string("0")))
  assert_true(truthy(Json::array([Json::null()])))
  assert_true(truthy(Json::number(-1.0)))
  let one = @jsonio.parse("{\"a\":1,\"b\":[1,{\"c\":null}]}")
  let same = @jsonio.parse("{\"b\":[1,{\"c\":null}],\"a\":1.0}")
  assert_true(json_equal(one, same))
  assert_false(
    json_equal(one, @jsonio.parse("{\"a\":1,\"b\":[{\"c\":null},1]}")),
  )
  assert_false(json_equal(one, @jsonio.parse("{\"a\":1}")))
  assert_false(json_equal(Json::string("1"), Json::number(1.0)))
  assert_false(json_equal(Json::null(), Json::boolean(false)))
  assert_eq(@jsonio.as_text(Json::string("x")), "x")
  assert_eq(@jsonio.as_text(Json::null()), "null")
  assert_eq(@jsonio.as_text(@jsonio.parse("{\"a\":[1]}")), "{\"a\":[1]}")
  assert_eq(
    show(first_set([Json::null(), Json::string("a"), Json::string("b")])),
    "\"a\"",
  )
  assert_eq(show(first_set([Json::null()])), "null")
}

///|
test "a thread is titled by the display name when there is one, else by the task" {
  let named = @jsonio.parse("{\"taskId\":\"TR1\",\"displayName\":\"Name\"}")
  assert_eq(thread_title("Impl", named), "Impl｜Name")
  for
    request in [
      "{\"taskId\":\"TR1\"}", "{\"taskId\":\"TR1\",\"displayName\":null}", "{\"taskId\":\"TR1\",\"displayName\":\"\"}",
    ] {
    assert_eq(thread_title("Review", @jsonio.parse(request)), "Review TR1")
  }
}

///|
test "settings a send kept are those it named, and a create always keeps them" {
  let create = @jsonio.parse(
    "{\"tool\":\"create_thread\",\"expected\":{\"model\":null,\"effort\":null},\"actual\":{\"model\":\"m\",\"effort\":\"e\"}}",
  )
  assert_eq(
    show(sent_settings(create)),
    "{\"requested\":{\"model\":null,\"effort\":null},\"actual\":{\"model\":\"m\",\"effort\":\"e\"}}",
  )
  let plain = @jsonio.parse(
    "{\"tool\":\"send_message_to_thread\",\"expected\":{\"model\":null,\"effort\":null}}",
  )
  assert_eq(show(sent_settings(plain)), "null")
  let asked = @jsonio.parse(
    "{\"tool\":\"send_message_to_thread\",\"expected\":{\"model\":\"m\"}}",
  )
  assert_eq(
    show(sent_settings(asked)),
    "{\"requested\":{\"model\":\"m\",\"effort\":null},\"actual\":{\"model\":null,\"effort\":null}}",
  )
  assert_eq(show(sent_settings(Json::null())), "null")
}
