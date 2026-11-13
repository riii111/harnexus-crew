///|
pub fn single_line(
  value : String,
  name : String,
) -> String raise @failure.TaskFailed {
  if @text.is_blank(value) ||
    value.code_units().iter().any(fn(unit) { unit < 32 }) {
    @failure.fail("\{name} must be a nonempty single-line string")
  }
  value
}

///|
/// A chat ID that the app confirmed: one line, no whitespace, and not the placeholder of a thread that does not exist yet.
pub fn chat_id(
  value : String,
  name : String,
) -> String raise @failure.TaskFailed {
  let id = single_line(value, name)
  if @text.has_space(id) || id.has_prefix("client-new-thread:") {
    @failure.fail("\{name} must be a confirmed chat ID without whitespace")
  }
  id
}

///|
pub fn caller_id(env : @environment.Env) -> String raise @failure.TaskFailed {
  let variable = @environment.thread_variable(@environment.app_of(env))
  match env.get_nonempty(variable) {
    Some(value) => chat_id(value, variable)
    None =>
      @failure.fail(
        "\{variable} is not set; run \{@environment.NAME} from a thread",
      )
  }
}

///|
fn task_id_of(value : Json?) -> String raise @failure.TaskFailed {
  // The task ID is an identifier in prompts, so reject whitespace and prose.
  let id = json_single_line(value, "taskId")
  let points = units_of(id)
  let first_ok = @text.is_ascii_alphanumeric(points[0]) ||
    points[0] == 0x5F ||
    points[0] == 0x23
  let rest_ok = points[1:]
    .iter()
    .all(fn(point) {
      @text.is_ascii_alphanumeric(point) || is_one_of(point, "_.#/:-")
    })
  if !(first_ok && rest_ok) {
    @failure.fail(
      "taskId must start with a letter, digit, _ or # and contain only letters, digits and _ . # / : -",
    )
  }
  id
}

///|
fn display_name_of(value : Json?) -> OptionalText raise @failure.TaskFailed {
  // The display name is used only in the thread title, so do not apply the ID character restrictions.
  match value {
    None => Absent
    Some(Null) => Null
    other => Text(json_single_line(other, "displayName"))
  }
}

///|
fn project_of(value : Json?, name : String) -> String raise @failure.TaskFailed {
  json_single_line(value, name)
}

///|
fn starting_branch_of(value : Json?) -> OptionalText raise @failure.TaskFailed {
  match value {
    None => Absent
    Some(Null) => Null
    Some(String(branch)) if is_branch_name(branch) => Text(branch)
    Some(_) => @failure.fail("startingBranch must be a branch name")
  }
}

///|
async fn document_refs_of(
  value : Json?,
  probe : FileProbe,
) -> Array[String] raise @failure.TaskFailed {
  let items = match value {
    Some(Array(items)) if !items.is_empty() => items
    _ => @failure.fail("documentRefs must be a nonempty list of paths or URLs")
  }
  let refs = []
  for item in items {
    let reference = json_single_line(Some(item), "documentRefs entry")
    if !is_https_url(reference) &&
      (!reference.has_prefix("/") || !(probe.path_exists)(reference)) {
      @failure.fail(
        "document reference must be an existing absolute path or HTTPS URL: \{reference}",
      )
    }
    refs.push(reference)
  }
  if refs.length() != unique_count(refs) {
    @failure.fail("documentRefs must not contain duplicate references")
  }
  refs
}

///|
fn is_branch_name(branch : String) -> Bool {
  let points = units_of(branch)
  points.length() > 0 &&
  (@text.is_ascii_alphanumeric(points[0]) || points[0] == 0x5F) &&
  points[1:]
  .iter()
  .all(fn(point) {
    @text.is_ascii_alphanumeric(point) || is_one_of(point, "_./-")
  }) &&
  !branch.contains("..") &&
  !branch.has_suffix(".lock") &&
  !branch.has_suffix("/") &&
  !branch.has_suffix(".")
}

///|
fn is_https_url(value : String) -> Bool {
  if @text.has_space(value) {
    return false
  }
  let units = value.code_units()
  let mut at = 0
  if units.length() == 0 || !is_ascii_letter(units[0].to_int()) {
    return false
  }
  while at < units.length() && is_scheme_unit(units[at].to_int()) {
    at += 1
  }
  if at + 2 >= units.length() ||
    units[at] != 0x3A ||
    units[at + 1] != 0x2F ||
    units[at + 2] != 0x2F {
    return false
  }
  let scheme = value[:at].to_owned().to_lower()
  let host_start = at + 3
  scheme == "https" &&
  host_start < units.length() &&
  units[host_start] != 0x2F &&
  units[host_start] != 0x3F &&
  units[host_start] != 0x23
}

///|
fn is_pull_request_url(value : String) -> Bool {
  if !value.has_prefix("https://") {
    return false
  }
  let parts = value["https://".length():]
    .to_owned()
    .split("/")
    .map(fn(part) { part.to_owned() })
    .collect()
  let count = parts.length()
  if count != 5 && count != 6 {
    return false
  }
  for index in 0..<3 {
    if parts[index] == "" || @text.has_space(parts[index]) {
      return false
    }
  }
  parts[3] == "pull" &&
  is_positive_number(parts[4]) &&
  (count == 5 || parts[5] == "")
}

///|
fn unique_count(refs : Array[String]) -> Int32 {
  let seen = Map([])
  for reference in refs {
    seen[reference] = true
  }
  seen.length()
}

///|
fn json_single_line(
  value : Json?,
  name : String,
) -> String raise @failure.TaskFailed {
  match value {
    Some(String(text)) => single_line(text, name)
    _ => @failure.fail("\{name} must be a nonempty single-line string")
  }
}

///|
fn is_positive_number(text : String) -> Bool {
  let units = text.code_units()
  units.length() > 0 &&
  units[0] >= 0x31 &&
  units[0] <= 0x39 &&
  units.iter().all(fn(unit) { unit >= 0x30 && unit <= 0x39 })
}

///|
fn is_one_of(point : Int32, allowed : String) -> Bool {
  allowed.code_units().iter().any(fn(unit) { unit.to_int() == point })
}

///|
fn is_ascii_letter(unit : Int32) -> Bool {
  (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
}

///|
fn is_scheme_unit(unit : Int32) -> Bool {
  is_ascii_letter(unit) ||
  (unit >= 0x30 && unit <= 0x39) ||
  unit == 0x2B ||
  unit == 0x2E ||
  unit == 0x2D
}

///|
fn units_of(text : String) -> Array[Int32] {
  text.code_units().map(unit => unit.to_int())
}

///|
fn read_request(
  json : Json,
  required : Array[String],
  optional : Array[String],
) -> Map[String, Json] raise @failure.TaskFailed {
  let members = match json {
    Object(members) => members
    _ => @failure.fail("request must be a JSON object")
  }
  let unknown = []
  for key, _ in members {
    if !required.contains(key) && !optional.contains(key) {
      unknown.push(key)
    }
  }
  if !unknown.is_empty() {
    unknown.sort_by(@text.compare_utf16)
    @failure.fail("unknown request fields: \{unknown.join(", ")}")
  }
  let missing = required.filter(fn(key) { !members.contains(key) })
  if !missing.is_empty() {
    missing.sort_by(@text.compare_utf16)
    @failure.fail("missing request fields: \{missing.join(", ")}")
  }
  members
}
