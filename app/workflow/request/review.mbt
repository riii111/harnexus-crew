///|
/// Where a review request may take its checkout from.
pub(all) enum ReviewScope {
  /// A worker worktree `<folder>/<id>/<name>` of an app, whose reviewer is started in that app.
  Worktrees(String)
  /// A Claude Code cloud session reviews in its own checkout, so any repository's top level will do and no app project is involved.
  Cloud
}

///|
pub struct ReviewRequest {
  task_id : String
  worker_ai : WorkerAi
  /// Absent only in Cloud, where no app project is involved.
  priv project_id : String?
  /// The real path of the top level of a repository.
  checkout : String
  priv base_branch : String
  priv document_refs : Array[String]
  priv display_name : OptionalText
  priv pr_url : String?
  worker_chat_id : String?
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
  let task_id = parse_task_id(members.get("taskId"))
  let display_name = parse_display_name(members.get("displayName"))
  let document_refs = parse_document_refs(members.get("documentRefs"), probe)

  let project_id = match members.get("projectId") {
    None if cloud => None
    value => Some(parse_project_id(value))
  }

  let requested = parse_single_line(members.get("checkout"), "checkout")
  let base_branch = parse_single_line(members.get("baseBranch"), "baseBranch")
  let worker_ai = parse_worker_ai(members.get("workerAI"))
  let pr_url = parse_pr_url(members.get("prUrl"))
  let checkout = resolve_checkout(requested, scope, probe, git)
  {
    task_id,
    worker_ai,
    project_id,
    checkout,
    base_branch,
    document_refs,
    display_name,
    pr_url,
    worker_chat_id: parse_worker_chat_id(members.get("workerChatId")),
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
/// What names the saved session of a review, before it is hashed: the same checkout reviewed for the same worker chat is the same session.
pub fn ReviewRequest::session_key(
  self : ReviewRequest,
  worker_chat_id : String,
) -> String {
  "\{self.checkout}\n\{worker_chat_id}"
}

///|
/// `previous` is the candidate recorded for the session, if any: its base is kept unless `update_base` asks for a new one, and a changed base branch is refused then.
pub async fn ReviewRequest::resolve_candidate(
  self : ReviewRequest,
  previous : Map[String, Json]?,
  update_base : Bool,
  git : @git.Git,
) -> ReviewCandidate raise @failure.TaskFailed {
  let head = git.run(self.checkout, ["rev-parse", "HEAD"])

  let base = match previous {
    Some(recorded) if !recorded.is_empty() && !update_base =>
      read_recorded_base(recorded, self.base_branch)
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
pub struct ReviewCandidate {
  priv request : ReviewRequest
  head : String
  base : String
}

///|
pub fn ReviewCandidate::to_json(self : ReviewCandidate) -> Json {
  let members = self.request.members()
  members["head"] = Json::string(self.head)
  members["base"] = Json::string(self.base)
  Json::object(members)
}

///|
fn parse_worker_ai(value : Json?) -> WorkerAi raise @failure.TaskFailed {
  match value {
    Some(String("Claude")) => Claude
    Some(String("Codex")) => Codex
    _ => @failure.fail("workerAI must be Claude or Codex")
  }
}

///|
fn parse_pr_url(value : Json?) -> String? raise @failure.TaskFailed {
  match value {
    None | Some(Null) => None
    Some(String(url)) if is_pull_request_url(url) => Some(url)
    Some(_) => @failure.fail("prUrl must be a pull request URL or null")
  }
}

///|
async fn resolve_checkout(
  requested : String,
  scope : ReviewScope,
  probe : FileProbe,
  git : @git.Git,
) -> String raise @failure.TaskFailed {
  let checkout = (probe.resolve_real_path_or_self)(requested)

  let (refused, in_place) = match scope {
    Cloud =>
      ("checkout must be the absolute path of a repository's top level", true)
    Worktrees(folder) => {
      let root = (probe.resolve_real_path_or_self)(folder)
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
fn parse_worker_chat_id(value : Json?) -> String? raise @failure.TaskFailed {
  match value {
    None | Some(Null) => None
    Some(String(id)) => Some(id)
    Some(_) => @failure.fail("workerChatId must be a string or null")
  }
}

///|
fn read_recorded_base(
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
