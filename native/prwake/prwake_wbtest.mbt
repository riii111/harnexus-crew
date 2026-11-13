///|
test "the deadline is ten minutes for a dry run and one minute for the rest" {
  assert_eq(timeout_of(["dry-run"]), 600000)
  assert_eq(timeout_of(["dry-run", "--pr", "a"]), 600000)
  for
    args in [
      ["status", "--json"],
      ["sender"],
      ["release", "dry-run"],
      ["link", "u", "--take-over"],
      [],
    ] {
    assert_eq(timeout_of(args), 60000)
  }
}

///|
async test "the printed object comes back and the environment reaches pr-wake" {
  with_rig("c-3", rig => {
    rig.plan(
      "pr-wake",
      1,
      out=" \u{FEFF}{\"watched\":\"u\",\"b\":2,\"10\":1,\"2\":0,\"a\":[1,{\"c\":null}]}\n\u{3000}",
      stderr="a warning that does not fail the call",
    )
    let printed = call(rig.env([("MARK_FROM_TEST", "yes")]), [
      "link", "https://github.com/o/r/pull/1", "--take-over",
    ])
    assert_eq(
      Json::object(printed),
      @jsonio.parse(
        "{\"watched\":\"u\",\"b\":2,\"10\":1,\"2\":0,\"a\":[1,{\"c\":null}]}",
      ),
    )
    assert_eq(
      rig.args("pr-wake", 1),
      "watch link https://github.com/o/r/pull/1 --take-over",
    )
    assert_true(
      rig.recorded("pr-wake", "env", 1).contains("\nMARK_FROM_TEST=yes\n"),
    )
  })
}

///|
async test "a failing pr-wake is reported with its trimmed stderr" {
  with_rig("c-4", rig => {
    rig.plan("pr-wake", 1, exit=3, stderr=" \u{A0}boom\n ", out="{}")
    rig.plan("pr-wake", 2, exit=2)
    rig.plan("pr-wake", 3, exit=1, stderr="\n \u{85}\n")
    assert_eq(
      failure_of(() => ignore(call(rig.env([]), ["status", "--json"]))),
      "pr-wake watch status --json failed with exit 3: boom",
    )
    assert_eq(
      failure_of(() => ignore(call(rig.env([]), ["release", "u"]))),
      "pr-wake watch release u failed with exit 2",
    )
    // U+0085 is not trimmed by JavaScript, so it counts as something said.
    assert_eq(
      failure_of(() => ignore(call(rig.env([]), ["sender"]))),
      "pr-wake watch sender failed with exit 1: \u{85}",
    )
  })
}

///|
async test "output that is not one JSON object fails even when pr-wake succeeded" {
  with_rig("c-5", rig => {
    let outputs = [
      "", "   \n", "not json", "[1]", "3", "null", "\"x\"", "true", "{\"a\":", "{} {}",
    ]
    for index, out in outputs {
      rig.plan("pr-wake", index + 1, out~)
      assert_eq(
        failure_of(() => ignore(call(rig.env([]), ["sender"]))),
        "pr-wake watch sender printed no JSON object",
        msg=out,
      )
    }
  })
}

///|
async test "a pr-wake past its deadline is stopped and reported" {
  serial(() => {
    with_rig("c-7", rig => {
      rig.plan("pr-wake", 1, sleep="30")
      let started = @async.now()
      let message = failure_of(() => {
        ignore(call_within(rig.env([]), ["status", "--json"], 200))
      })
      assert_eq(
        message, "pr-wake was stopped after 200 ms; install pr-wake, or set HARNEXUS_CREW_PR_WAKE to its absolute path",
      )
      assert_true(@async.now() - started < 10000)
    })
  })
}
