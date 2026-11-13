///|
/// Which prompt a template is for.
pub(all) enum TemplateKind {
  Worker
  Reviewer
}

///|
fn TemplateKind::name(self : TemplateKind) -> String {
  match self {
    Worker => "worker"
    Reviewer => "reviewer"
  }
}

///|
/// The prompt a new chat receives: the configured template of `kind`, with its links resolved and `fields` filled in.
pub fn task_prompt(
  env : @environment.Env,
  kind : TemplateKind,
  fields : Map[String, String],
) -> String raise @failure.TaskFailed {
  let config_path = template_config_path(env)
  if !@store.path_exists(config_path) {
    @failure.fail(
      "\{config_path} does not exist; set templates.\{kind.name()} there to the \{kind.name()} prompt template",
    )
  }
  let config = read_config(config_path)
  let configured = match kind {
    Worker => config.worker
    Reviewer => config.reviewer
  }
  match configured {
    Some(path) => render_as(kind, path, fields)
    None =>
      @failure.fail("templates.\{kind.name()} is not set in \{config_path}")
  }
}

///|
/// Renders every configured template as launch and review would, so an update can tell before it is switched to that it cannot fill them.
/// A template that is not configured is only named.
pub fn check_templates(
  env : @environment.Env,
) -> Json raise @failure.TaskFailed {
  let config_path = template_config_path(env)
  if !@store.path_exists(config_path) {
    return checked(None, None, Json::null())
  }
  let config = read_config(config_path)
  if config.worker is Some(path) {
    ignore(render_as(Worker, path, @request.sample_worker_fields()))
  }
  let mut t3 = Json::null()
  if config.reviewer is Some(path) {
    for reply in replies {
      ignore(render_as(Reviewer, path, @request.sample_reviewer_fields(reply)))
    }
    t3 = t3_readiness(path)
  }
  checked(config.worker, config.reviewer, t3)
}

///|
/// The replies a reviewer template must be filled for: a worker in the Codex App of either AI, and a Claude Code cloud session.
let replies : Array[String] = ["Codex", "Claude", "Cloud"]

///|
/// A worker in T3 Code, whose reply only T3 Code needs, so a template written before T3 Code is still installed and the review in T3 Code refuses it before sending.
const T3_REPLY : String = "T3"

///|
fn t3_readiness(path : String) -> Json {
  try {
    ignore(render_as(Reviewer, path, @request.sample_reviewer_fields(T3_REPLY)))
    object([("ready", Json::boolean(true))])
  } catch {
    @failure.TaskFailed(reason) =>
      object([("ready", Json::boolean(false)), ("reason", Json::string(reason))])
  }
}

///|
fn checked(worker : String?, reviewer : String?, t3 : Json) -> Json {
  object([
    (
      "templates",
      object([
        ("worker", name_or_null(worker)),
        ("reviewer", name_or_null(reviewer)),
      ]),
    ),
    ("t3", t3),
  ])
}

///|
fn name_or_null(path : String?) -> Json {
  match path {
    Some(path) => Json::string(path)
    None => Json::null()
  }
}

///|
fn object(members : Array[(String, Json)]) -> Json {
  Json::object(Map::from_array(members))
}

///|
fn read_config(
  config_path : String,
) -> TemplateConfig raise @failure.TaskFailed {
  let json = @jsonio.parse(read_text(config_path)) catch {
    _ => @failure.fail("\{config_path} is not valid JSON")
  }
  TemplateConfig::from_json(config_path, json)
}

///|
fn read_text(path : String) -> String raise @failure.TaskFailed {
  @store.read_regular_text(path) catch {
    failed => @failure.fail(failed.user_message())
  }
}

///|
fn render_as(
  kind : TemplateKind,
  path : String,
  fields : Map[String, String],
) -> String raise @failure.TaskFailed {
  render(path, fields) catch {
    @failure.TaskFailed(message) =>
      @failure.fail("the \{kind.name()} template \{path}: \{message}")
  }
}

///|
fn render(
  path : String,
  fields : Map[String, String],
) -> String raise @failure.TaskFailed {
  let template = read_text(path)
  @template.format(resolve_links(template, path, fields), fields)
}
