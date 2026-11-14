///|
test "a dry run has a ten minute deadline" {
  for args in [["dry-run"], ["dry-run", "--pr", "a"]] {
    assert_eq(timeout_of(args), 600000, msg=args.join(" "))
  }
}

///|
test "any other subcommand has a one minute deadline" {
  for
    args in [
      ["status", "--json"],
      ["sender"],
      ["release", "dry-run"],
      ["link", "u", "--take-over"],
      [],
    ] {
    assert_eq(timeout_of(args), 60000, msg=args.join(" "))
  }
}

///|
async test "the object pr-wake prints comes back, whatever surrounds it" {
  with_pr_wake("c-3", rig => {
    rig.plan(
      1,
      name="pr-wake",
      out=" \u{FEFF}{\"watched\":\"u\",\"b\":2,\"10\":1,\"2\":0,\"a\":[1,{\"c\":null}]}\n\u{3000}",
      stderr="a warning that does not fail the call",
    )

    let printed = call(rig.env([]), ["sender"])

    assert_eq(
      Json::object(printed),
      @jsonio.parse(
        "{\"watched\":\"u\",\"b\":2,\"10\":1,\"2\":0,\"a\":[1,{\"c\":null}]}",
      ),
    )
  })
}

///|
async test "pr-wake is run with watch and the subcommand's arguments" {
  with_pr_wake("c-3b", rig => {
    rig.plan(1, name="pr-wake", out="{}")

    ignore(
      call(rig.env([]), ["link", "https://github.com/o/r/pull/1", "--take-over"]),
    )

    assert_eq(rig.args(1, name="pr-wake"), [
      "watch", "link", "https://github.com/o/r/pull/1", "--take-over",
    ])
  })
}

///|
async test "the caller's environment reaches pr-wake" {
  with_pr_wake("c-3c", rig => {
    rig.plan(1, name="pr-wake", out="{}")

    ignore(call(rig.env([("MARK_FROM_TEST", "yes")]), ["sender"]))

    let marks = rig
      .recorded("env", 1, name="pr-wake")
      .split("\n")
      .filter(line => line.has_prefix("MARK_"))
      .map(line => line.to_owned())
      .collect()

    assert_eq(marks, ["MARK_FROM_TEST=yes"])
  })
}

///|
async test "a failing pr-wake is reported with its exit status and trimmed stderr" {
  with_pr_wake("c-4", rig => {
    rig.plan(1, name="pr-wake", exit=3, stderr=" \u{A0}boom\n ", out="{}")

    let message = @app_testkit.failure_of(() => {
      ignore(call(rig.env([]), ["status", "--json"]))
    })

    assert_eq(message, "pr-wake watch status --json failed with exit 3: boom")
  })
}

///|
async test "a failing pr-wake that said nothing is reported with its exit status only" {
  with_pr_wake("c-4b", rig => {
    rig.plan(1, name="pr-wake", exit=2)

    let message = @app_testkit.failure_of(() => {
      ignore(call(rig.env([]), ["release", "u"]))
    })

    assert_eq(message, "pr-wake watch release u failed with exit 2")
  })
}

///|
async test "stderr counts as said when it holds only U+0085, which JavaScript does not trim" {
  with_pr_wake("c-4c", rig => {
    rig.plan(1, name="pr-wake", exit=1, stderr="\n \u{85}\n")

    let message = @app_testkit.failure_of(() => {
      ignore(call(rig.env([]), ["sender"]))
    })

    assert_eq(message, "pr-wake watch sender failed with exit 1: \u{85}")
  })
}

///|
async test "output that is not one JSON object fails even when pr-wake succeeded" {
  with_pr_wake("c-5", rig => {
    let outputs = [
      "", "   \n", "not json", "[1]", "3", "null", "\"x\"", "true", "{\"a\":", "{} {}",
    ]

    for index, out in outputs {
      rig.plan(index + 1, name="pr-wake", out~)

      assert_eq(
        @app_testkit.failure_of(() => ignore(call(rig.env([]), ["sender"]))),
        "pr-wake watch sender printed no JSON object",
        msg=out,
      )
    }
  })
}

///|
async test "a pr-wake past its deadline is stopped and reported" {
  @testkit.serial(() => {
    with_pr_wake("c-7", rig => {
      rig.plan(1, name="pr-wake", sleep="30")

      let (message, elapsed) = @testkit.timed(() => {
        @app_testkit.failure_of(() => {
          ignore(call_within(rig.env([]), ["status", "--json"], 200))
        })
      })

      assert_eq(
        message, "pr-wake was stopped after 200 ms; install pr-wake, or set HARNEXUS_CREW_PR_WAKE to its absolute path",
      )
      @testkit.assert_between(elapsed, 0, 10000)
    })
  })
}

///|
async test "the engine is looked up beside the resolved pr-wake, not the link to it" {
  @app_testkit.with_fake_cli(
    "c-8",
    mock="pr-wake.sh",
    stand_ins=["pr-wake", "pr-wake-engine"],
    rig => {
      let links = "\{rig.root}/links"
      @store.prepare_directory(links) catch {
        failed => abort(failed.user_message())
      }
      @fs.symlink(target="\{rig.bin}/pr-wake", "\{links}/pr-wake") catch {
        _ => abort("cannot link pr-wake")
      }

      let found = name => {
        if name == "pr-wake" {
          Some("\{links}/pr-wake")
        } else {
          None
        }
      }

      let stopped = run_watch_engine(rig.env([]), which=found)

      assert_eq(stopped, Json::object({ "watch": Json::string("stopped") }))

      assert_true(rig.ran(name="pr-wake-engine"))

      assert_false(rig.ran(name="pr-wake"))
    },
  )
}

///|
async fn with_pr_wake(
  name : String,
  body : async (@app_testkit.FakeCli) -> Unit,
) -> Unit {
  @app_testkit.with_fake_cli(
    name,
    mock="pr-wake.sh",
    stand_ins=["pr-wake"],
    body,
  )
}
