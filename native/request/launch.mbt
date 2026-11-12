///|
pub struct LaunchRequest {
  task_id : String
  display_name : OptionalText
  project_id : String
  starting_branch : OptionalText
  document_refs : Array[String]
  completion_target : CompletionTarget
}

///|
/// Reports the first problem in the order the TypeScript build checked.
pub async fn LaunchRequest::from_json(
  json : Json,
  probe : FileProbe,
) -> LaunchRequest raise @failure.TaskFailed {
  let members = read_request(
    json,
    ["taskId", "documentRefs", "completionTarget", "projectId"],
    ["startingBranch", "displayName"],
  )
  let task_id = task_id_of(members.get("taskId"))
  let display_name = display_name_of(members.get("displayName"))
  let project_id = project_of(members.get("projectId"), "projectId")
  let starting_branch = starting_branch_of(members.get("startingBranch"))
  let document_refs = document_refs_of(members.get("documentRefs"), probe)
  let completion_target = completion_target_of(members.get("completionTarget"))
  {
    task_id,
    display_name,
    project_id,
    starting_branch,
    document_refs,
    completion_target,
  }
}

///|
/// The request as it is saved, with the members it had: a name or branch that was null stays null and one that was absent stays absent.
pub fn LaunchRequest::to_json(self : LaunchRequest) -> Json {
  let members : Map[String, Json] = {
    "taskId": Json::string(self.task_id),
    "documentRefs": Json::array(
      self.document_refs.map(fn(reference) { Json::string(reference) }),
    ),
    "completionTarget": Json::string(self.completion_target.name()),
    "projectId": Json::string(self.project_id),
  }
  add_optional(members, "startingBranch", self.starting_branch)
  add_optional(members, "displayName", self.display_name)
  Json::object(members)
}

///|
/// What names the saved session of a request, before it is hashed: the same task in the same project is the same session.
/// Text that leaves JSON for a hash goes through `lossy_text`, as UTF-8 encoding does in JS.
pub fn LaunchRequest::session_key(self : LaunchRequest) -> String {
  @jsonio.lossy_text("\{self.project_id}\n\{self.task_id}")
}

///|
fn completion_target_of(
  value : Json?,
) -> CompletionTarget raise @failure.TaskFailed {
  match value {
    Some(String("implementation")) => Implementation
    Some(String("draft_pr")) => DraftPr
    Some(String("merge")) => Merge
    _ =>
      @failure.fail(
        "completionTarget must be implementation, draft_pr, or merge",
      )
  }
}

///|
fn add_optional(
  members : Map[String, Json],
  key : String,
  value : OptionalText,
) -> Unit {
  match value {
    Absent => ()
    Null => members[key] = Json::null()
    Text(text) => members[key] = Json::string(text)
  }
}
