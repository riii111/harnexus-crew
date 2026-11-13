///|
fn crash_run(error : Error) -> @run.CommandRun {
  {
    code: 1,
    stdout: "",
    stderr: "\{@environment.NAME}: unexpected failure: \{error}\n\{feedback_hint}\n",
  }
}
