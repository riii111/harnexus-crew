///|
pub struct TemplateConfig {
  worker : String?
  reviewer : String?
}

///|
/// Beside harnexus's other config, never in the repository or the working directory, so a sandboxed agent cannot pick the prompt a new chat receives.
pub fn template_config_path(env : @environment.Env) -> String {
  @path.join([env.config_home(), "task.json"])
}

///|
/// Problems are listed in the order and words of the zod schema the TypeScript build used.
pub fn TemplateConfig::from_json(
  path : String,
  json : Json,
) -> TemplateConfig raise @failure.TaskFailed {
  let issues : Array[Issue] = []
  let config = read_root(json, issues)
  if issues.is_empty() {
    config
  } else {
    @failure.fail("\{path} is invalid: \{pretty(issues)}")
  }
}

///|
priv struct Issue {
  path : Array[String]
  message : String
}

///|
fn read_root(json : Json, issues : Array[Issue]) -> TemplateConfig {
  match json {
    Object(members) => {
      let mut config = { worker: None, reviewer: None, }
      match members.get("templates") {
        Some(Object(templates)) => config = read_templates(templates, issues)
        Some(other) =>
          issues.push(wrong_type(["templates"], "object", Some(other)))
        None => issues.push(wrong_type(["templates"], "object", None))
      }
      let unknown = keys_except(members, ["templates"])
      if !unknown.is_empty() {
        issues.push({ path: [], message: unrecognized(unknown), })
      }
      config
    }
    other => {
      issues.push(wrong_type([], "object", Some(other)))
      { worker: None, reviewer: None, }
    }
  }
}

///|
fn read_templates(
  templates : Map[String, Json],
  issues : Array[Issue],
) -> TemplateConfig {
  let worker = read_template(templates, "worker", issues)
  let reviewer = read_template(templates, "reviewer", issues)
  let unknown = keys_except(templates, ["worker", "reviewer"])
  if !unknown.is_empty() {
    issues.push({ path: ["templates"], message: unrecognized(unknown), })
  }
  { worker, reviewer, }
}

///|
fn read_template(
  templates : Map[String, Json],
  kind : String,
  issues : Array[Issue],
) -> String? {
  let path = ["templates", kind]
  match templates.get(kind) {
    None => None
    Some(String(text)) =>
      if text.has_prefix("/") {
        Some(text)
      } else {
        issues.push({ path, message: "must be absolute", })
        None
      }
    Some(other) => {
      issues.push(wrong_type(path, "string", Some(other)))
      None
    }
  }
}

///|
fn wrong_type(path : Array[String], expected : String, found : Json?) -> Issue {
  {
    path,
    message: "Invalid input: expected \{expected}, received \{type_name(found)}",
  }
}

///|
fn type_name(json : Json?) -> String {
  match json {
    None => "undefined"
    Some(Null) => "null"
    Some(True) | Some(False) => "boolean"
    Some(Number(_)) => "number"
    Some(String(_)) => "string"
    Some(Array(_)) => "array"
    Some(Object(_)) => "object"
  }
}

///|
fn keys_except(
  members : Map[String, Json],
  known : Array[String],
) -> Array[String] {
  let indexes : Array[(Int64, String)] = []
  let names = []
  for key, _ in members {
    if known.contains(key) {
      continue
    }
    match array_index(key) {
      Some(index) => indexes.push((index, key))
      None => names.push(key)
    }
  }
  // JS lists the keys that are array indexes first and in numeric order, so zod prints them that way.
  indexes.sort_by(fn(a, b) { a.0.compare(b.0) })
  indexes.map(fn(pair) { pair.1 }) + names
}

///|
fn array_index(key : String) -> Int64? {
  let units = key.code_units()
  if units.length() == 0 ||
    units.length() > 10 ||
    (units.length() > 1 && units[0] == 0x30) ||
    !units.iter().all(fn(unit) { unit >= 0x30 && unit <= 0x39 }) {
    return None
  }
  let mut value : Int64 = 0
  for unit in units {
    value = value * 10 + (unit.to_int() - 0x30).to_int64()
  }
  if value < 4294967295L {
    Some(value)
  } else {
    None
  }
}

///|
fn unrecognized(keys : Array[String]) -> String {
  let quoted = keys.map(fn(key) { "\"\{key}\"" }).join(", ")
  if keys.length() == 1 {
    "Unrecognized key: \{quoted}"
  } else {
    "Unrecognized keys: \{quoted}"
  }
}

///|
/// Issues with the shortest path first and otherwise as found, as zod's `prettifyError` lists them.
fn pretty(issues : Array[Issue]) -> String {
  let lines = []
  for depth in 0..<=2 {
    for issue in issues {
      if issue.path.length() == depth {
        lines.push("✖ \{issue.message}")
        if depth > 0 {
          lines.push("  → at \{issue.path.join(".")}")
        }
      }
    }
  }
  lines.join("\n")
}
