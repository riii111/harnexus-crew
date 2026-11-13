///|
/// Where a review request may take its checkout from.
pub(all) enum ReviewScope {
  /// A worker worktree `<folder>/<id>/<name>` of an app, whose reviewer is started in that app.
  /// The folder is the app's worktree folder, such as the one `Env::worktrees` names.
  Worktrees(String)
  /// A Claude Code cloud session reviews in its own checkout, so any repository's top level will do and no app project is involved.
  Cloud
}

///|
/// A request to review a worker's checkout against a base branch.
pub struct ReviewRequest {
  task_id : String
  worker_ai : WorkerAi
  /// Absent only in Cloud, where no app project is involved.
  project_id : String?
  /// The real path of the top level of a repository.
  checkout : String
  base_branch : String
  document_refs : Array[String]
  display_name : OptionalText
  pr_url : String?
  worker_chat_id : String?
}

///|
/// A review request with the two commits it covers.
pub struct ReviewCandidate {
  request : ReviewRequest
  head : String
  base : String
}

///|
pub async fn ReviewRequest::from_json(
  json : Json,
  scope : ReviewScope,
  probe : FileProbe,
  git : @git.Git,
) -> ReviewRequest raise @failure.TaskFailed {
  let cloud = scope is Cloud
  let project = ["projectId"]
  let members = read_request(
    json,
    ["taskId", "workerAI"] +
    (if cloud { [] } else { project }) +
    ["checkout", "baseBranch", "documentRefs"],
    ["prUrl", "workerChatId", "displayName"] +
    (if cloud { project } else { [] }),
  )
  let task_id = task_id_of(members.get("taskId"))
  let display_name = display_name_of(members.get("displayName"))
  let document_refs = document_refs_of(members.get("documentRefs"), probe)
  let project_id = match members.get("projectId") {
    None if cloud => None
    value => Some(project_of(value, "projectId"))
  }
  let requested = json_single_line(members.get("checkout"), "checkout")
  let base_branch = json_single_line(members.get("baseBranch"), "baseBranch")
  let worker_ai = worker_ai_of(members.get("workerAI"))
  let pr_url = pr_url_of(members.get("prUrl"))
  let checkout = checkout_of(requested, scope, probe, git)
  {
    task_id,
    worker_ai,
    project_id,
    checkout,
    base_branch,
    document_refs,
    display_name,
    pr_url,
    worker_chat_id: worker_chat_id_of(members.get("workerChatId")),
  }
}

///|
pub fn ReviewRequest::with_worker_chat_id(
  self : ReviewRequest,
  id : String,
) -> ReviewRequest {
  { ..self, worker_chat_id: Some(id), }
}

///|
/// The request as it is saved: the pull request URL is always there, null when none was given.
pub fn ReviewRequest::to_json(self : ReviewRequest) -> Json {
  Json::object(self.members())
}

///|
/// What names the saved session of a review, before it is hashed: the same checkout reviewed for the same worker chat is the same session.
pub fn ReviewRequest::session_key(
  self : ReviewRequest,
  worker_chat_id : String,
) -> String {
  "\{self.checkout}\n\{worker_chat_id}"
}

///|
/// Resolves the commits of a review.
/// `previous` is the candidate recorded for the session, if any: its base is kept unless `update_base` asks for a new one, and a changed base branch is refused then.
pub async fn ReviewRequest::candidate(
  self : ReviewRequest,
  previous : Map[String, Json]?,
  update_base : Bool,
  git : @git.Git,
) -> ReviewCandidate raise @failure.TaskFailed {
  let head = git.run(self.checkout, ["rev-parse", "HEAD"])
  let base = match previous {
    Some(recorded) if !recorded.is_empty() && !update_base =>
      recorded_base(recorded, self.base_branch)
    _ => resolve_base(self, git)
  }
  let merged = git.run(self.checkout, ["merge-base", base, head])
  if merged != base {
    @failure.fail("review base must be an ancestor of head")
  }
  { request: self, head, base, }
}

///|
fn ReviewRequest::members(self : ReviewRequest) -> Map[String, Json] {
  let members : Map[String, Json] = {
    "taskId": Json::string(self.task_id),
    "workerAI": Json::string(self.worker_ai.name()),
    "checkout": Json::string(self.checkout),
    "baseBranch": Json::string(self.base_branch),
    "documentRefs": Json::array(
      self.document_refs.map(fn(reference) { Json::string(reference) }),
    ),
    "prUrl": match self.pr_url {
      Some(url) => Json::string(url)
      None => Json::null()
    },
  }
  match self.project_id {
    Some(id) => members["projectId"] = Json::string(id)
    None => ()
  }
  match self.worker_chat_id {
    Some(id) => members["workerChatId"] = Json::string(id)
    None => ()
  }
  add_optional(members, "displayName", self.display_name)
  members
}

///|
/// The candidate as it is saved: the request with its commits.
pub fn ReviewCandidate::to_json(self : ReviewCandidate) -> Json {
  let members = self.request.members()
  members["head"] = Json::string(self.head)
  members["base"] = Json::string(self.base)
  Json::object(members)
}

///|
fn worker_ai_of(value : Json?) -> WorkerAi raise @failure.TaskFailed {
  match value {
    Some(String("Claude")) => Claude
    Some(String("Codex")) => Codex
    _ => @failure.fail("workerAI must be Claude or Codex")
  }
}

///|
fn worker_chat_id_of(value : Json?) -> String? raise @failure.TaskFailed {
  match value {
    None | Some(Null) => None
    Some(String(id)) => Some(id)
    Some(_) => @failure.fail("workerChatId must be a string or null")
  }
}

///|
fn pr_url_of(value : Json?) -> String? raise @failure.TaskFailed {
  match value {
    None | Some(Null) => None
    Some(String(url)) if is_pull_request_url(url) => Some(url)
    Some(_) => @failure.fail("prUrl must be a pull request URL or null")
  }
}

///|
async fn checkout_of(
  requested : String,
  scope : ReviewScope,
  probe : FileProbe,
  git : @git.Git,
) -> String raise @failure.TaskFailed {
  let checkout = (probe.real_path_or_self)(requested)
  let (refused, in_place) = match scope {
    Cloud =>
      ("checkout must be the absolute path of a repository's top level", true)
    Worktrees(folder) => {
      let root = (probe.real_path_or_self)(folder)
      (
        "checkout must be the top level of a worker worktree \{root}/<id>/<name>",
        @path.dirname(@path.dirname(checkout)) == root,
      )
    }
  }
  if !requested.has_prefix("/") || !in_place || !(probe.is_directory)(checkout) {
    @failure.fail(refused)
  }
  let top = git.run(checkout, ["rev-parse", "--show-toplevel"])
  if top != checkout {
    @failure.fail(refused)
  }
  checkout
}

///|
fn recorded_base(
  recorded : Map[String, Json],
  base_branch : String,
) -> String raise @failure.TaskFailed {
  match recorded.get("baseBranch") {
    None | Some(Null) => ()
    Some(String(branch)) if branch == base_branch => ()
    Some(_) =>
      @failure.fail(
        "baseBranch changed; use --update-base after integrating upstream",
      )
  }
  match recorded.get("base") {
    Some(String(base)) => base
    _ => @failure.fail("the recorded review candidate has no base")
  }
}

///|
async fn resolve_base(
  request : ReviewRequest,
  git : @git.Git,
) -> String raise @failure.TaskFailed {
  let reference = git.run(request.checkout, [
    "rev-parse",
    "--symbolic-full-name",
    "--verify",
    "--end-of-options",
    request.base_branch,
  ])
  if !reference.has_prefix("refs/heads/") &&
    !reference.has_prefix("refs/remotes/") {
    @failure.fail("baseBranch must name a local or remote branch")
  }
  git.run(request.checkout, ["rev-parse", "--verify", "\{reference}^{commit}"])
}
