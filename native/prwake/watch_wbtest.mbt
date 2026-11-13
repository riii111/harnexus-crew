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
