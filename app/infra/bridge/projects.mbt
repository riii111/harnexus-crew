///|
/// The ID of the listed project whose real path is `directory`'s.
pub fn find_project_id(result : Json?, directory : String) -> String? {
  let real = @store.resolve_real_path_or_self(directory)
  for project in projects_in(result) {
    if project is Object(members) &&
      members.get("projectId") is Some(String(project_id)) &&
      members.get("path") is Some(String(path)) &&
      @store.resolve_real_path_or_self(path) == real {
      return Some(project_id)
    }
  }
  None
}

///|
/// The projects a `list_projects` result carries, wherever the app put them: structured content, the result itself, or JSON text in its content.
fn projects_in(result : Json?) -> Array[Json] {
  guard result is Some(Object(members) as whole) else { return [] }
  let candidates = [members.get("structuredContent"), Some(whole)]
  if members.get("content") is Some(Array(content)) {
    for item in content {
      if text_content(item) is Some(text) {
        candidates.push(Some(@jsonio.parse(text) catch { _ => Json::null() }))
      }
    }
  }
  for candidate in candidates {
    if candidate is Some(Object(listed)) &&
      listed.get("projects") is Some(Array(projects)) {
      return projects
    }
  }
  []
}

///|
fn text_content(item : Json) -> String? {
  guard item is Object(members) else { return None }
  guard members.get("type") is Some(String("text")) else { return None }
  match members.get("text") {
    Some(String(text)) => Some(text)
    _ => None
  }
}
