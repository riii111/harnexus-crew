///|
/// argv    : Arguments after `adapter`.
/// read_env: Called only once the arguments are accepted and the command needs the environment.
pub async fn run(
  argv : ArrayView[String],
  read_env : () -> @environment.Env raise,
) -> @run.CommandRun {
  let (command, rest) = match argv {
    [] => return usage_error("expected serve")
    [command, .. rest] => (command, rest)
  }
  if command == "-h" || command == "--help" {
    return { code: 0, stdout: usage(@environment.NAME), stderr: "", }
  }
  if command == "serve" {
    let id = @args.parse_adapter_serve(rest) catch {
      @args.UsageError(message) => return usage_error(message)
    }
    guard id is Some(id) && is_adapter_id(id) else {
      return usage_error("--id ADAPTER_ID is required: letters, digits, _ . -")
    }
    return serve(read_env(), id)
  }
  usage_error("unknown adapter command \{command}")
}

///|
fn usage_error(message : String) -> @run.CommandRun {
  let name = @environment.NAME
  { code: 2, stdout: "", stderr: "\{usage(name)}\{name}: \{message}\n", }
}

///|
fn usage(name : String) -> String {
  "usage:\n  \{name} adapter serve --id ADAPTER_ID\n"
}

///|
/// An adapter id the bridge can name in its logs: 1 to 64 ASCII letters, digits, `_`, `.` and `-`.
fn is_adapter_id(text : String) -> Bool {
  let units = text.code_units()
  if units.length() < 1 || units.length() > 64 {
    return false
  }
  units
  .iter()
  .all(unit => {
    let code = unit.to_int()
    (code >= 48 && code <= 57) ||
    (code >= 65 && code <= 90) ||
    (code >= 97 && code <= 122) ||
    code == 95 ||
    code == 46 ||
    code == 45
  })
}
