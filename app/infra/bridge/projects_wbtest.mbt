///|
test "projects come from structured content first, then the result, then JSON text in its content" {
  inspect(
    projects_of(
      "{\"structuredContent\":{\"projects\":[{\"projectId\":\"a\"}]},\"projects\":[{\"projectId\":\"b\"}]}",
    ),
    content="[{\"projectId\":\"a\"}]",
  )

  inspect(
    projects_of(
      "{\"projects\":[{\"projectId\":\"b\"}],\"content\":[{\"type\":\"text\",\"text\":\"{\\\"projects\\\":[1,2]}\"}]}",
    ),
    content="[{\"projectId\":\"b\"}]",
  )

  inspect(
    projects_of(
      "{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"projects\\\":[1,2]}\"}]}",
    ),
    content="[1,2]",
  )
}

///|
test "a content text that is not JSON is passed over" {
  inspect(
    projects_of(
      "{\"content\":[{\"type\":\"text\",\"text\":\"nope\"},{\"type\":\"text\",\"text\":\"{\\\"projects\\\":[3]}\"}]}",
    ),
    content="[3]",
  )
}

///|
test "a projects field that is not a list is passed over" {
  inspect(
    projects_of("{\"structuredContent\":{\"projects\":3},\"projects\":[9]}"),
    content="[9]",
  )
}

///|
test "an empty projects list is taken, not passed over" {
  inspect(
    projects_of("{\"structuredContent\":{\"projects\":[]},\"projects\":[9]}"),
    content="[]",
  )
}

///|
test "a content item that is not text is passed over" {
  inspect(
    projects_of(
      "{\"content\":[{\"type\":\"image\",\"text\":\"{\\\"projects\\\":[1]}\"},{\"type\":\"text\",\"text\":5},{\"type\":\"text\",\"text\":\"{\\\"projects\\\":[2]}\"}]}",
    ),
    content="[2]",
  )
}

///|
test "a result without a projects list holds no projects" {
  assert_eq(projects_of("{\"projects\":[1]}"), "[1]")

  assert_eq(projects_in(None), [])

  for text in ["null", "[]", "\"x\"", "{}", "{\"content\":3}"] {
    assert_eq(projects_of(text), "[]", msg=text)
  }
}

///|
fn projects_of(text : String) -> String {
  json_text(Json::array(projects_in(Some(parse(text)))))
}
