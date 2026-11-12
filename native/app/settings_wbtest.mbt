///|
fn settings(model : String?, effort : String?) -> TurnSettings {
  { model, effort, }
}

///|
test "a turn that ran as asked is not refused" {
  inspect(
    refusal_of(settings(Some("m"), None), settings(Some("m"), None)),
    content="",
  )
  inspect(
    refusal_of(settings(None, Some("high")), settings(Some("x"), Some("high"))),
    content="",
  )
  inspect(
    refusal_of(settings(None, None), settings(Some("a"), Some("b"))),
    content="",
  )
}

///|
test "each setting that differs is named, model first" {
  inspect(
    refusal_of(
      settings(Some("m"), Some("high")),
      settings(Some("n"), Some("low")),
    ),
    content="asked for model n instead of m and asked for effort low instead of high",
  )
  inspect(
    refusal_of(settings(Some("m"), Some("high")), settings(None, None)),
    content="did not say which model (expected m) and did not say which effort (expected high)",
  )
  inspect(
    refusal_of(settings(Some("m"), None), settings(None, Some("x"))),
    content="did not say which model (expected m)",
  )
}
