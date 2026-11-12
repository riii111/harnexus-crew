///|
fn projects_of(text : String) -> String {
  json_text(Json::array(projects_in(Some(parse(text)))))
}

///|
test "projects come from structured content first, then the result, then JSON text in its content" {
  inspect(
    projects_of(
      "{\"structuredContent\":{\"projects\":[{\"projectId\":\"a\"}]},\"projects\":[{\"projectId\":\"b\"}]}",
    ),
    content="[{\"projectId\":\"a\"}]",
  )
  inspect(
    projects_of("{\"projects\":[{\"projectId\":\"b\"}],\"content\":[]}"),
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
test "a text that is not JSON, or a field that is not a list, is passed over" {
  inspect(
    projects_of(
      "{\"content\":[{\"type\":\"text\",\"text\":\"nope\"},{\"type\":\"text\",\"text\":\"{\\\"projects\\\":[]}\"}]}",
    ),
    content="[]",
  )
  inspect(
    projects_of("{\"structuredContent\":{\"projects\":3},\"projects\":[9]}"),
    content="[9]",
  )
  inspect(
    projects_of("{\"structuredContent\":{\"projects\":[]},\"projects\":[9]}"),
    content="[]",
  )
  inspect(
    projects_of(
      "{\"content\":[{\"type\":\"image\",\"text\":\"{\\\"projects\\\":[1]}\"},{\"type\":\"text\",\"text\":5}]}",
    ),
    content="[]",
  )
}

///|
test "anything but an object holds no projects" {
  inspect(projects_in(None).length(), content="0")
  for text in ["null", "[]", "\"x\"", "{}", "{\"content\":3}"] {
    inspect(projects_of(text), content="[]")
  }
}
