///|
/// The values a worker template is filled with.
pub async fn LaunchRequest::build_worker_fields(
  self : LaunchRequest,
  probe : FileProbe,
) -> Map[String, String] raise @failure.TaskFailed {
  {
    "task_id": self.task_id,
    "document_refs": render_document_block(self.document_refs, probe),
    "completion_target": self.completion_target.name(),
  }
}

///|
/// The values a reviewer template is filled with.
pub async fn ReviewCandidate::build_reviewer_fields(
  self : ReviewCandidate,
  reply_to : String,
  probe : FileProbe,
) -> Map[String, String] raise @failure.TaskFailed {
  let request = self.request
  let worker_chat_id = match request.worker_chat_id {
    Some(id) => id
    None => @failure.fail("workerChatId must be the chat ID of the worker")
  }
  {
    "task_id": request.task_id,
    "document_refs": render_document_block(request.document_refs, probe),
    "worker_ai": request.worker_ai.name(),
    "reply_to": reply_to,
    "worker_chat_id": worker_chat_id,
    "checkout": request.checkout,
    "pr_url": request.pr_url.unwrap_or("null"),
    "base": self.base,
    "head": self.head,
  }
}

///|
/// The worker template's values for a sample task, so a check sees exactly the fields a launch gives.
pub fn sample_worker_fields() -> Map[String, String] {
  {
    "task_id": "check",
    "document_refs": "- https://example.com/task",
    "completion_target": "draft_pr",
  }
}

///|
/// The reviewer template's values for a sample task, so a check sees exactly the fields a review gives.
pub fn sample_reviewer_fields(reply_to : String) -> Map[String, String] {
  let zeros = "0000000000000000000000000000000000000000"
  {
    "task_id": "check",
    "document_refs": "- https://example.com/task",
    "worker_ai": "Codex",
    "reply_to": reply_to,
    "worker_chat_id": "check",
    "checkout": "/",
    "pr_url": "null",
    "base": zeros,
    "head": zeros,
  }
}

///|
async fn render_document_block(
  refs : Array[String],
  probe : FileProbe,
) -> String raise @failure.TaskFailed {
  // The files may have gone since the request was read, so the document references are checked again.
  let checked = parse_document_refs(
    Some(Json::array(refs.map(fn(reference) { Json::string(reference) }))),
    probe,
  )
  checked.map(fn(reference) { "- \{reference}" }).join("\n")
}
