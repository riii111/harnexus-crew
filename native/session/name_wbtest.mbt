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
