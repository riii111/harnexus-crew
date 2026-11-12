///|
/// A test driver: `test/test_prompt.py` runs it to fill a template.
/// Arguments: HOME, XDG_CONFIG_HOME, `worker` or `reviewer`, then the template's `name=value` fields.
/// It is not part of the CLI.
fn main {
  let args = @env.args()
  let env = @environment.Env::new(
    { "HOME": arg(args, 1), "XDG_CONFIG_HOME": arg(args, 2) },
    login_home="",
  )
  let kind : @prompt.TemplateKind = if arg(args, 3) == "reviewer" {
    Reviewer
  } else {
    Worker
  }
  let fields : Map[String, String] = Map([])
  for field in args[4:] {
    if field.find("=") is Some(at) {
      fields[field[:at].to_owned()] = field[at + 1:].to_owned()
    }
  }
  let reply = Json::object({
    "prompt": Json::string(@prompt.task_prompt(env, kind, fields)),
  }) catch {
    @failure.TaskFailed(message) =>
      Json::object({ "error": Json::string(message) })
  }
  @sys.write_text(1, @jsonio.stringify(reply) + "\n") catch {
    _ => abort("cannot write")
  }
}

///|
fn arg(args : Array[String], index : Int32) -> String {
  args.get(index).unwrap_or("")
}
