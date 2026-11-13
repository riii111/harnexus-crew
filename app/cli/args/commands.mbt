///|
pub enum Command {
  Launch(@workflow.LaunchInput)
  Review(@workflow.ReviewInput)
  State(@workflow.StateInput)
  Resolve(@workflow.ResolveInput)
  Name(@workflow.NameInput)
  Watch(@workflow.WatchInput)
  Environment
  Check
  Cloud(@workflow.CloudInput)
}

///|
/// What reading a command's arguments came to.
pub enum Parsed {
  /// `-h` or `--help` was given, and nothing else was wrong.
  Help
  Run(Command)
}

///|
/// The commands in the order the usage lists them.
pub fn command_names() -> Array[String] {
  [
    "launch", "review", "state", "resolve", "name", "watch", "environment", "check",
    "cloud",
  ]
}

///|
/// Reads the arguments after a command's name.
/// The caller has checked the name against `command_names`.
pub fn parse_command(
  command : String,
  rest : ArrayView[String],
) -> Parsed raise UsageError {
  let specs = specs_of(command)
  specs.push({ name: "help", kind: Flag, })
  let options = parse_options(rest, specs)
  if options.flag("help") {
    return Help
  }
  Run(command_of(command, options))
}

///|
/// Reads the arguments after `adapter serve`, which takes no `--help`; the id is None when it was not given.
pub fn parse_adapter_serve(
  rest : ArrayView[String],
) -> String? raise UsageError {
  parse_options(rest, [{ name: "id", kind: Text, }]).text("id")
}

///|
fn specs_of(command : String) -> Array[OptionSpec] {
  let text = fn(name : String) -> OptionSpec { { name, kind: Text, } }
  let flag = fn(name : String) -> OptionSpec { { name, kind: Flag, } }
  match command {
    "launch" => [text("request"), text("model"), text("thinking")]
    "review" =>
      [
        text("request"),
        text("ask"),
        text("model"),
        text("thinking"),
        flag("update-base"),
        text("recover"),
      ]
    "state" => [text("request")]
    "resolve" =>
      [text("request"), flag("sent"), flag("not-sent"), text("thread-id")]
    "name" => [text("pr")]
    "watch" =>
      [
        flag("dry-run"),
        { name: "pr", kind: TextList, },
        text("release"),
        flag("status"),
        flag("sender"),
        text("link"),
      ]
    "cloud" =>
      [
        text("link"),
        text("prompt-file"),
        text("project"),
        text("title"),
        text("model"),
        text("thinking"),
      ]
    _ => []
  }
}

///|
fn command_of(
  command : String,
  options : ParsedOptions,
) -> Command raise UsageError {
  match command {
    "launch" =>
      Launch({
        request: required(options, "request"),
        model: options.text("model"),
        thinking: options.text("thinking"),
      })
    "review" => Review(review_args(options))
    "state" => State({ request: options.text("request"), })
    "resolve" => Resolve(resolve_args(options))
    "name" => Name({ pr: required(options, "pr"), })
    "watch" => Watch(watch_args(options))
    "cloud" => Cloud(cloud_args(options))
    "environment" => Environment
    _ => Check
  }
}

///|
fn review_args(
  options : ParsedOptions,
) -> @workflow.ReviewInput raise UsageError {
  let ask = options.text("ask")
  // The reviewer keeps the model it was started with, so a question takes no model either.
  if ask is Some(_) &&
    (
      options.flag("update-base") ||
      options.text("recover") is Some(_) ||
      options.text("model") is Some(_) ||
      options.text("thinking") is Some(_)
    ) {
    raise UsageError(
      "--ask takes none of --update-base, --recover, --model and --thinking",
    )
  }
  let request = required(options, "request")
  let discard_pending = match options.text("recover") {
    None => false
    Some("discard") => true
    Some(_) => raise UsageError("--recover must be one of discard")
  }
  {
    request,
    model: options.text("model"),
    thinking: options.text("thinking"),
    update_base: options.flag("update-base"),
    discard_pending,
    ask,
  }
}

///|
fn resolve_args(
  options : ParsedOptions,
) -> @workflow.ResolveInput raise UsageError {
  let request = required(options, "request")
  if options.flag("sent") == options.flag("not-sent") {
    raise UsageError("exactly one of --sent and --not-sent is required")
  }
  { request, sent: options.flag("sent"), thread_id: options.text("thread-id"), }
}

///|
fn watch_args(options : ParsedOptions) -> @workflow.WatchInput raise UsageError {
  let args : @workflow.WatchInput = {
    dry_run: options.flag("dry-run"),
    prs: options.list("pr"),
    release: options.text("release"),
    status: options.flag("status"),
    sender: options.flag("sender"),
    link: options.text("link"),
  }
  if !args.prs.is_empty() && !args.dry_run {
    raise UsageError("--pr is only for --dry-run")
  }
  let modes = [
    args.release is Some(_),
    args.dry_run,
    args.status,
    args.sender,
    args.link is Some(_),
  ]
  if modes.filter(fn(on) { on }).length() > 1 {
    raise UsageError(
      "use only one of --dry-run, --release, --status, --sender and --link",
    )
  }
  args
}

///|
fn cloud_args(options : ParsedOptions) -> @workflow.CloudInput raise UsageError {
  let link = options.text("link")
  let prompt_file = options.text("prompt-file")
  if (link is None) == (prompt_file is None) {
    raise UsageError("exactly one of --link and --prompt-file is required")
  }
  {
    link,
    prompt_file,
    project: options.text("project"),
    title: options.text("title"),
    model: options.text("model"),
    thinking: options.text("thinking"),
  }
}

///|
fn required(options : ParsedOptions, name : String) -> String raise UsageError {
  match options.text(name) {
    Some(value) => value
    None => raise UsageError("--\{name} is required")
  }
}
