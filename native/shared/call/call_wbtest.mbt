///|
test "only outcomes after which the bridge did not act are unsent" {
  let names = [
    "done", "tool_error", "not_sent", "rejected", "invalid", "unknown", "model_mismatch",
    "first_turn_refused", "chat_not_opened", "unsupported",
  ]
  let unsent = []
  for name in names {
    let outcome = CallOutcome::from_name(name).unwrap()
    inspect(outcome.name(), content=name)
    if outcome.is_unsent() {
      unsent.push(name)
    }
  }
  inspect(unsent.join(","), content="not_sent,rejected,invalid,unsupported")
}

///|
test "an outcome the program does not know is never unsent" {
  let answer = CallAnswer::of_json(
    @jsonio.parse("{\"outcome\":\"newly_added\",\"threadId\":\"t\"}"),
  )
  inspect(answer.is_unsent(), content="false")
}

///|
test "an answer keeps the fields it was not asked about" {
  let answer = CallAnswer::of_json(
    @jsonio.parse("{\"outcome\":\"done\",\"later\":[1],\"threadId\":\"t\"}"),
  )
  inspect(
    @jsonio.stringify(answer.to_json()),
    content="{\"later\":[1],\"threadId\":\"t\",\"outcome\":\"done\"}",
  )
}

///|
test "an answer without an outcome is refused" {
  let message = try {
    CallAnswer::of_json(@jsonio.parse("{\"threadId\":\"t\"}")) |> ignore
    "accepted"
  } catch {
    @jsonio.JsonError(message) => message
  }
  inspect(message, content="bridge answer.outcome must be a string")
}
