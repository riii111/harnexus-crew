///|
/// A test driver: `test/test_prompt.py` runs it to fill a template.
/// args[1] : HOME.
/// args[2] : XDG_CONFIG_HOME.
/// args[3] : `worker` or `reviewer`.
/// args[4:]: The template's `name=value` fields.
/// It is not part of the CLI.
fn main {
  let args = @env.args()
  let env = @environment.Env::new({
    "HOME": arg(args, 1),
    "XDG_CONFIG_HOME": arg(args, 2),
  })
  let kind : @prompts.TemplateKind = if arg(args, 3) == "reviewer" {
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
    "prompt": Json::string(@prompts.task_prompt(env, kind, fields)),
  }) catch {
    @failure.TaskFailed(message) =>
      Json::object({ "error": Json::string(message) })
  }
  @sys.write_text(1, reply.stringify() + "\n") catch {
    _ => abort("cannot write")
  }
}

///|
fn arg(args : Array[String], index : Int32) -> String {
  args.get(index).unwrap_or("")
}
