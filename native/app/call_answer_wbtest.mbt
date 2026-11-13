///|
test "only outcomes after which the bridge did not act are unsent" {
  let names = [
    "done", "tool_error", "not_sent", "rejected", "invalid", "unknown", "model_mismatch",
    "first_turn_refused", "chat_not_opened", "unsupported", "newly_added",
  ]
  let unsent = names.filter(name => {
    CallAnswer::of_json({ "outcome": Json::string(name) }).unwrap().is_unsent()
  })
  inspect(unsent.join(","), content="not_sent,rejected,invalid,unsupported")
}

///|
test "an answer keeps the fields it was not asked about" {
  let answer = CallAnswer::of_json(
    @jsonio.parse("{\"later\":[1],\"outcome\":\"done\",\"threadId\":\"t\"}"),
  ).unwrap()
  assert_eq(answer.outcome, "done")
  assert_eq(
    answer.to_json(),
    @jsonio.parse("{\"outcome\":\"done\",\"later\":[1],\"threadId\":\"t\"}"),
  )
}

///|
test "an answer without a string outcome is refused" {
  assert_true(
    CallAnswer::of_json(@jsonio.parse("{\"threadId\":\"t\"}")) is None,
  )
  assert_true(CallAnswer::of_json(@jsonio.parse("{\"outcome\":1}")) is None)
}
