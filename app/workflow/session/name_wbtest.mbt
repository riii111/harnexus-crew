///|
async test "no launch is found for a thread while there is no launch directory" {
  with_rig("n-7", [], rig => {
    assert_eq(find_launch_request(rig.env([]), "w1").map(show), None)
  })
}

///|
async test "the launch of a thread is found among the launches by their state, skipping unreadable ones" {
  with_rig("n-8", [], rig => {
    let env = rig.env([])
    let launches = "\{rig.root}/state/harnexus-crew/launch"
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

    assert_eq(
      find_launch_request(env, "w1").map(show),
      Some("{\"taskId\":\"D\"}"),
    )
    assert_eq(find_launch_request(env, "w3").map(show), None)
  })
}

///|
test "a value counts as present unless it is null, false, zero or empty" {
  let cases = [
    (Json::null(), false),
    (Json::boolean(false), false),
    (Json::number(0.0), false),
    (Json::string(""), false),
    (Json::array([]), false),
    (Json::object({}), false),
    (Json::string("0"), true),
    (Json::array([Json::null()]), true),
    (Json::number(-1.0), true),
  ]
  for entry in cases {
    let (value, present) = entry
    assert_eq(truthy(value), present, msg=value.stringify())
  }
}

///|
test "the first value that is not null is chosen" {
  assert_eq(
    show(first_set([Json::null(), Json::string("a"), Json::string("b")])),
    "\"a\"",
  )
}

///|
test "null is chosen when every value is null" {
  assert_eq(show(first_set([Json::null()])), "null")
}

///|
test "a thread is titled by the display name when there is one" {
  let named = @jsonio.parse("{\"taskId\":\"TR1\",\"displayName\":\"Name\"}")

  assert_eq(thread_title("Impl", named), "Impl｜Name")
}

///|
test "a thread without a display name is titled by the task" {
  for
    request in [
      "{\"taskId\":\"TR1\"}", "{\"taskId\":\"TR1\",\"displayName\":null}", "{\"taskId\":\"TR1\",\"displayName\":\"\"}",
    ] {
    assert_eq(
      thread_title("Review", @jsonio.parse(request)),
      "Review TR1",
      msg=request,
    )
  }
}

///|
test "a create keeps the settings it was given, named or not" {
  let create = @jsonio.parse(
    "{\"tool\":\"create_thread\",\"expected\":{\"model\":null,\"effort\":null},\"actual\":{\"model\":\"m\",\"effort\":\"e\"}}",
  )

  assert_eq(
    show(sent_settings(create)),
    "{\"requested\":{\"model\":null,\"effort\":null},\"actual\":{\"model\":\"m\",\"effort\":\"e\"}}",
  )
}

///|
test "a send keeps the settings it named" {
  let asked = @jsonio.parse(
    "{\"tool\":\"send_message_to_thread\",\"expected\":{\"model\":\"m\"}}",
  )

  assert_eq(
    show(sent_settings(asked)),
    "{\"requested\":{\"model\":\"m\",\"effort\":null},\"actual\":{\"model\":null,\"effort\":null}}",
  )
}

///|
test "a send that named no settings keeps none" {
  let plain = @jsonio.parse(
    "{\"tool\":\"send_message_to_thread\",\"expected\":{\"model\":null,\"effort\":null}}",
  )

  assert_eq(show(sent_settings(plain)), "null", msg="send without settings")
  assert_eq(show(sent_settings(Json::null())), "null", msg="no record")
}
