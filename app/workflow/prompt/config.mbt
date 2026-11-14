///|
priv struct TemplateConfig {
  worker : String?
  reviewer : String?
}

///|
fn TemplateConfig::from_json(
  path : String,
  json : Json,
) -> TemplateConfig raise @failure.TaskFailed {
  guard json is Object(members) else {
    fail_invalid(path, "it must be an object")
  }

  if unknown_key(members, ["templates"]) is Some(key) {
    fail_invalid(path, "unknown field \"\{key}\"")
  }

  guard members.get("templates") is Some(Object(templates)) else {
    fail_invalid(path, "templates must be an object")
  }

  if unknown_key(templates, ["worker", "reviewer"]) is Some(key) {
    fail_invalid(path, "unknown field \"templates.\{key}\"")
  }

  let parse_template_path = fn(
    kind : String,
  ) -> String? raise @failure.TaskFailed {
    match templates.get(kind) {
      None => None
      Some(String(text)) if text.has_prefix("/") => Some(text)
      Some(_) =>
        fail_invalid(path, "templates.\{kind} must be an absolute path")
    }
  }

  {
    worker: parse_template_path("worker"),
    reviewer: parse_template_path("reviewer"),
  }
}

///|
fn template_config_path(env : @environment.Env) -> String {
  // To keep the working repository from overriding prompt settings, use the user configuration directory.
  @path.join([env.config_home(), "task.json"])
}

///|
fn unknown_key(members : Map[String, Json], known : Array[String]) -> String? {
  for key, _ in members {
    if !known.contains(key) {
      return Some(key)
    }
  }

  None
}

///|
fn[T] fail_invalid(
  path : String,
  problem : String,
) -> T raise @failure.TaskFailed {
  @failure.fail("\{path} is invalid: \{problem}")
}
