///|
/// The review a journal line holds, read leniently since only its key decides what is handed over.
fn journaled_review(
  members : Map[String, Json],
  key : String,
) -> @app.CloudReview {
  {
    key,
    reviewer: text_or_none(members.get("reviewer")).unwrap_or(""),
    verdict: text_or_none(members.get("verdict")),
    task_id: text_or_none(members.get("taskId")),
    head: text_or_none(members.get("head")),
    answer: text_or_none(members.get("answer")).unwrap_or(""),
  }
}

///|
/// Moves the reviews the journal recorded while only observing into the waiting list, except those harnexus or another adapter already sent or reserved.
/// It runs while no adapter runs.
async fn hand_over(
  observations : Observations,
  store : ReviewStore,
  journal : Array[Json],
) -> Json raise @failure.TaskFailed {
  let queued : Map[String, Bool] = Map([])
  for entry in observations.pending() {
    queued[entry.review.key] = true
  }
  let added : Array[PendingReview] = []
  let mut skipped = 0
  for line in journal {
    let kind = text_member(line, "kind")
    guard kind == Some("observed_review") || kind == Some("legacy_unsent") else {
      continue
    }
    guard field(line, "review") is Some(Object(review) as raw) &&
      review.get("key") is Some(String(key)) &&
      text_member(line, "parentThreadId") is Some(parent_thread_id) else {
      continue
    }
    if queued.contains(key) {
      continue
    }
    queued[key] = true
    if store.state_of(key) is Sent || store.is_reserved(key) {
      skipped += 1
      observations.note([
        ("kind", Json::string("handover_skipped")),
        ("key", Json::string(key)),
      ])
      continue
    }
    added.push({
      parent_thread_id,
      session_id: text_member(line, "sessionId"),
      review: journaled_review(review, key),
      raw: Some(raw),
    })
    observations.note([
      ("kind", Json::string("handed_over")),
      ("key", Json::string(key)),
    ])
  }
  observations.add_pending(added)
  object([
    ("handedOver", Json::number(added.length().to_double())),
    ("skipped", Json::number(skipped.to_double())),
  ])
}

///|
fn journal_of(path : String) -> Array[Json] raise @failure.TaskFailed {
  let text = io(() => @store.read_text_if_exists(path)).unwrap_or("")
  let lines = []
  for line in text.split("\n") {
    let line = line.to_owned()
    if @text.js_trim(line) == "" {
      continue
    }
    if (Ok(@jsonio.parse(line)) catch { e => Err(e) })
      is Ok(Object(_) as parsed) {
      lines.push(parsed)
    }
  }
  lines
}
