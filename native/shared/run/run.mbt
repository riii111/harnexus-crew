///|
/// What one command prints and the code it exits with.
pub(all) struct CommandRun {
  code : Int32
  stdout : String
  stderr : String
}

///|
/// Writes stdout and then stderr, and exits with the code.
/// A result that cannot be written is not reported as a success.
pub fn finish(run : CommandRun) -> Unit {
  let wrote = try {
    @sys.write_text(1, run.stdout)
    @sys.write_text(2, run.stderr)
    true
  } catch {
    @sys.WriteFailed(..) => false
  }
  @env.exit(if wrote || run.code != 0 { run.code } else { 1 })
}
