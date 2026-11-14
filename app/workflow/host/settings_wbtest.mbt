///|
test "a turn that ran as asked is not refused" {
  assert_eq(
    refusal_of(settings(Some("m"), None), settings(Some("m"), None)),
    "",
    msg="same model",
  )
  assert_eq(
    refusal_of(settings(None, Some("high")), settings(Some("x"), Some("high"))),
    "",
    msg="model nobody asked for",
  )
  assert_eq(
    refusal_of(settings(None, None), settings(Some("a"), Some("b"))),
    "",
    msg="nothing asked",
  )
  assert_eq(
    refusal_of(settings(Some("m"), None), settings(Some("n"), None)),
    "asked for model n instead of m",
    msg="another model",
  )
}

///|
test "each setting that ran differently is named, model first" {
  assert_eq(
    refusal_of(
      settings(Some("m"), Some("high")),
      settings(Some("n"), Some("low")),
    ),
    "asked for model n instead of m and asked for effort low instead of high",
  )
}

///|
test "each setting the app did not say is named with what was expected" {
  assert_eq(
    refusal_of(settings(Some("m"), Some("high")), settings(None, None)),
    "did not say which model (expected m) and did not say which effort (expected high)",
    msg="both",
  )
  assert_eq(
    refusal_of(settings(Some("m"), None), settings(None, Some("x"))),
    "did not say which model (expected m)",
    msg="model only",
  )
}

///|
fn settings(model : String?, effort : String?) -> TurnSettings {
  { model, effort, }
}
