///|
/// The arguments as `watch` receives them from the command line.
fn watch_args(argv : Array[String]) -> @args.WatchArgs {
  let parsed = @args.parse_command("watch", argv[:]) catch {
    _ => abort("not accepted: \{argv.join(" ")}")
  }
  match parsed {
    Run(Watch(args)) => args
    _ => abort("not a watch command: \{argv.join(" ")}")
  }
}

///|
async fn watched(
  rig : Rig,
  args : @args.WatchArgs,
  extra~ : Array[(String, String)] = [],
) -> String raise @failure.TaskFailed {
  watch(args, rig.env(extra), which=rig.which()).stringify()
}

///|
async test "each option is passed to pr-wake as the subcommand it names" {
  with_rig("w-1", rig => {
    let cases = [
      (
        watch_args(["--release", "https://github.com/o/r/pull/3"]),
        "watch release https://github.com/o/r/pull/3",
      ),
      (watch_args(["--status"]), "watch status --json"),
      (watch_args(["--sender"]), "watch sender"),
      (
        watch_args(["--link", "https://github.com/o/r/pull/4"]),
        "watch link https://github.com/o/r/pull/4",
      ),
      (watch_args(["--dry-run"]), "watch dry-run"),
      (
        watch_args([
          "--dry-run", "--pr", "a", "--pr", "https://github.com/o/r/pull/5",
        ]),
        "watch dry-run --pr a --pr https://github.com/o/r/pull/5",
      ),
    ]
    for index, pair in cases {
      let (args, expected) = pair
      rig.plan("pr-wake", index + 1, out="{\"mode\":\{index}}")
      assert_eq(watched(rig, args), "{\"mode\":\{index}}")
      assert_eq(rig.args("pr-wake", index + 1), expected)
    }
    assert_false(rig.ran("pr-wake-engine"))
  })
}

///|
async test "a PR that is not on github.com is refused without calling pr-wake" {
  with_rig("w-2", rig => {
    let message = failure_of(() => {
      ignore(
        watched(rig, watch_args(["--link", "https://example.com/o/r/pull/1"])),
      )
    })
    assert_eq(
      message, "https://example.com/o/r/pull/1 is not watched: the PR watch needs the URL https://github.com/<owner>/<repo>/pull/<number>",
    )
    assert_false(rig.ran("pr-wake"))
  })
}

///|
async test "the watch is refused in the Cloud before anything runs" {
  with_rig("w-3", rig => {
    for
      args in [
        watch_args(["--status"]),
        watch_args(["--link", "https://github.com/o/r/pull/1"]),
        watch_args([]),
      ] {
      let message = failure_of(() => {
        ignore(watched(rig, args, extra=[("HARNEXUS_EXECUTION_ENV", "cloud")]))
      })
      assert_true(message.contains("watch"), msg=message)
    }
    assert_false(rig.ran("pr-wake"))
    assert_false(rig.ran("pr-wake-engine"))
  })
}

///|
async test "failures of pr-wake end the watch with its message" {
  with_rig("w-4", rig => {
    rig.plan("pr-wake", 1, exit=5, stderr="denied")
    assert_eq(
      failure_of(() => ignore(watched(rig, watch_args(["--sender"])))),
      "pr-wake watch sender failed with exit 5: denied",
    )
  })
}

///|
async test "without an option the long-running watch is handed to the engine beside pr-wake" {
  with_rig("w-5", rig => {
    assert_eq(watched(rig, watch_args([])), "{\"watch\":\"stopped\"}")
    assert_eq(rig.args("pr-wake-engine", 1), "watch")
    assert_false(rig.ran("pr-wake"))
  })
}

///|
async test "an engine that exits non-zero fails the watch with its status" {
  with_rig("w-6", rig => {
    rig.plan("pr-wake-engine", 1, exit=4)
    assert_eq(
      failure_of(() => ignore(watched(rig, watch_args([])))),
      "\{rig.bin}/pr-wake-engine watch exited with 4",
    )
  })
}

///|
async test "the engine is looked up beside the resolved pr-wake, not the link to it" {
  with_rig("w-7", rig => {
    let links = "\{rig.root}/links"
    @store.prepare_directory(links) catch {
      failed => abort(failed.user_message())
    }
    shell("ln", ["-s", "\{rig.bin}/pr-wake", "\{links}/pr-wake"])
    let found = name => {
      if name == "pr-wake" {
        Some("\{links}/pr-wake")
      } else {
        None
      }
    }
    let stopped = watch(watch_args([]), rig.env([]), which=found)
    assert_eq(stopped.stringify(), "{\"watch\":\"stopped\"}")
    assert_true(rig.ran("pr-wake-engine"))
    assert_false(rig.ran("pr-wake"))
  })
}

///|
async test "an absolute pr-wake path names the engine beside it, and a missing engine cannot run" {
  with_rig("w-8", rig => {
    let set = [("HARNEXUS_CREW_PR_WAKE", "\{rig.root}/nowhere/pr-wake")]
    assert_eq(
      failure_of(() => ignore(watched(rig, watch_args([]), extra=set))),
      "cannot run \{rig.root}/nowhere/pr-wake-engine",
    )
    let relative = [("HARNEXUS_CREW_PR_WAKE", "bin/pr-wake")]
    assert_eq(
      failure_of(() => ignore(watched(rig, watch_args([]), extra=relative))),
      "HARNEXUS_CREW_PR_WAKE must be an absolute path",
    )
    assert_false(rig.ran("pr-wake-engine"))
  })
}

///|
async test "pr-wake missing from PATH is reported with how to install it" {
  with_rig("w-9", rig => {
    let message = failure_of(() => {
      ignore(watch(watch_args([]), rig.env([]), which=_ => None))
    })
    assert_eq(
      message, "pr-wake is not on PATH; install pr-wake, or set HARNEXUS_CREW_PR_WAKE to its absolute path",
    )
  })
}
