///|
async test "without an option the watch is handed to pr-wake's engine" {
  @app_testkit.with_fake_cli(
    "w-7",
    mock="pr-wake.sh",
    stand_ins=["pr-wake", "pr-wake-engine"],
    rig => {
      let input : @workflow.WatchInput = {
        dry_run: false,
        prs: [],
        release: None,
        status: false,
        sender: false,
        link: None,
      }
      let found = name => {
        if name == "pr-wake" {
          Some("\{rig.bin}/pr-wake")
        } else {
          None
        }
      }

      let stopped = watch(input, rig.env([]), which=found)

      assert_eq(stopped, Json::object({ "watch": Json::string("stopped") }))
      assert_true(rig.ran(name="pr-wake-engine"))
      assert_false(rig.ran(name="pr-wake"))
    },
  )
}
