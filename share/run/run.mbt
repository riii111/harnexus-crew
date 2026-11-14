///|
pub(all) struct CommandRun {
  code : Int32
  stdout : String
  stderr : String
}

///|
/// Writes the output and exits the process.
pub fn finish(run : CommandRun) -> Unit {
  let wrote = try {
    @sys.write_text(1, run.stdout)
    @sys.write_text(2, run.stderr)
    true
  } catch {
    @sys.WriteFailed(..) => false
  }

  // A result that cannot be written must not be reported as a success, so a successful code becomes 1.
  @env.exit(if wrote || run.code != 0 { run.code } else { 1 })
}
