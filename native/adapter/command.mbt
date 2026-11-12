///|
fn usage(name : String) -> String {
  "usage:\n  \{name} adapter serve --id ADAPTER_ID\n  \{name} adapter handover\n  \{name} adapter export-links\n  \{name} adapter import-links FILE\n"
}

///|
fn usage_error(message : String) -> @run.CommandRun {
  let name = @environment.NAME
  { code: 2, stdout: "", stderr: "\{usage(name)}\{name}: \{message}\n", }
}

///|
fn failure_run(message : String) -> @run.CommandRun {
  { code: 1, stdout: "", stderr: "\{@environment.NAME}: \{message}\n", }
}

///|
fn printed(value : Json) -> @run.CommandRun {
  { code: 0, stdout: @jsonio.stringify(value) + "\n", stderr: "", }
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

///|
fn read_json(path : String) -> Json raise @failure.TaskFailed {
  let text = io(() => @store.read_regular_text(path))
  @jsonio.parse(text) catch {
    _ => @failure.fail("\{path} is not valid JSON")
  }
}

///|
/// `argv` is the arguments after `adapter`.
/// `read_env` is called only once the arguments are accepted and the command needs the environment.
pub async fn run(
  argv : ArrayView[String],
  read_env : () -> @environment.Env raise,
) -> @run.CommandRun {
  let (command, rest) = match argv {
    [] =>
      return usage_error(
        "expected serve, handover, export-links or import-links",
      )
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
  if rest.length() > (if command == "import-links" { 1 } else { 0 }) {
    return usage_error("\{command} takes no more arguments")
  }
  match command {
    "handover" => handover(read_env())
    "export-links" => {
      let env = read_env()
      printed(export_links(env)) catch {
        @failure.TaskFailed(message) => failure_run(message)
      }
    }
    "import-links" =>
      match rest {
        [file] => import_file(file, read_env)
        _ => usage_error("import-links needs the links file")
      }
    _ => usage_error("unknown adapter command \{command}")
  }
}

///|
async fn handover(env : @environment.Env) -> @run.CommandRun {
  try {
    let parts = build_parts(env)
    let journal = journal_of(parts.observations.journal_path())
    printed(hand_over(parts.observations, parts.store, journal))
  } catch {
    @failure.TaskFailed(message) => failure_run(message)
  }
}

///|
fn import_file(
  file : String,
  read_env : () -> @environment.Env raise,
) -> @run.CommandRun raise {
  let value = read_json(file) catch {
    @failure.TaskFailed(message) => return failure_run(message)
  }
  let env = read_env()
  printed(import_links(env, value)) catch {
    @failure.TaskFailed(message) => failure_run(message)
  }
}
