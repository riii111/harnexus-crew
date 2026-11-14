///|
/// What the adapter has seen of one Cloud session's reviews.
priv struct SessionPosition {
  session_id : String
  mut parent_thread_id : String
  baseline : Baseline
  /// The last record whose reviews were taken, or None before any was.
  mut cursor : String?
  /// The reviews before the baseline, and every review taken since, so a session read again from its start is never opened twice.
  excluded : Array[String]
  taken : Array[String]
}

///|
/// The record up to which reviews were in the session before the adapter first saw it, which are never opened.
/// It is estimated when the bridge could only say what the app was last shown.
priv struct Baseline {
  uuid : String?
  estimated : Bool
  at : String
}

///|
/// A review waiting to be shown, with the chat whose session ran it.
priv struct PendingReview {
  parent_thread_id : String
  session_id : String?
  review : @host.CloudReview
}

///|
/// A reviewer's chat asked for and not yet seen open: the review it opens with and the session that ran it, kept on disk so a restart neither asks again nor loses the text.
/// `showing` is set before the text is shown, so a stop between showing it and removing the record never shows it twice.
priv struct Opening {
  key : String
  text : String
  session_id : String?
  showing : Bool
}

///|
/// Where the adapter keeps what it has seen of each Cloud session, apart from what the app shows.
priv struct Observations {
  root : String
}

///|
fn Observations::new(root : String) -> Observations {
  { root, }
}

///|
fn Observations::read_position(
  self : Observations,
  session_id : String,
) -> SessionPosition? raise @failure.TaskFailed {
  if !is_session_id(session_id) {
    @failure.fail("\{session_id} is not a Cloud session id")
  }
  let path = self.session_path(session_id)
  let loaded = @store.read_json_or_null(path)
  if loaded is Null {
    return None
  }
  match position_in(loaded) {
    Some(found) => Some(found)
    None => @failure.fail("\{path} is not a session position")
  }
}

///|
fn Observations::keep_position(
  self : Observations,
  next : SessionPosition,
) -> Unit raise @failure.TaskFailed {
  @store.save_json(
    self.session_path(next.session_id),
    next.to_json(),
    exclusive=false,
  )
}

///|
fn Observations::read_opening(
  self : Observations,
  reviewer : String,
) -> Opening? raise @failure.TaskFailed {
  let path = self.opening_path(reviewer)
  let loaded = @store.read_json_or_null(path)
  if loaded is Null {
    return None
  }
  guard loaded is Object(members) &&
    members.get("key") is Some(String(key)) &&
    members.get("text") is Some(String(text)) else {
    @failure.fail("\{path} is not an opening record")
  }
  Some({
    key,
    text,
    session_id: text_or_none(members.get("sessionId")),
    showing: members.get("showing") is Some(True),
  })
}

///|
fn Observations::keep_opening(
  self : Observations,
  reviewer : String,
  value : Opening,
) -> Unit raise @failure.TaskFailed {
  @store.save_json(
    self.opening_path(reviewer),
    value.to_json(),
    exclusive=false,
  )
}

///|
fn Observations::drop_opening(
  self : Observations,
  reviewer : String,
) -> Unit raise @failure.TaskFailed {
  lift_file_failure(() => @store.remove_file(self.opening_path(reviewer)))
}

///|
fn Observations::read_pending(
  self : Observations,
) -> Array[PendingReview] raise @failure.TaskFailed {
  let path = self.pending_path()
  let loaded = @store.read_json_or_null(path)
  if loaded is Null {
    return []
  }
  if !(loaded is Array(_)) {
    @failure.fail("\{path} is not a list")
  }
  pending_in(loaded)
}

///|
async fn Observations::add_pending(
  self : Observations,
  added : Array[PendingReview],
) -> Unit raise @failure.TaskFailed {
  self.change_pending(entries => {
    let keys : Map[String, Bool] = Map([])
    for entry in entries {
      keys[entry.review.key] = true
    }
    let next = entries.copy()
    for entry in added {
      if !keys.contains(entry.review.key) {
        next.push(entry)
      }
    }
    next
  })
}

///|
async fn Observations::remove_pending(
  self : Observations,
  keys : Map[String, Bool],
) -> Unit raise @failure.TaskFailed {
  self.change_pending(entries => {
    entries.filter(entry => !keys.contains(entry.review.key))
  })
}

///|
/// The waiting list is shared by every adapter on the machine, so each change re-reads it under a lock and touches only its own entries.
async fn Observations::change_pending(
  self : Observations,
  change : (Array[PendingReview]) -> Array[PendingReview],
) -> Unit raise @failure.TaskFailed {
  @store.with_lock(self.locks_directory(), "pending", () => {
    let entries = self.read_pending()
    self.keep_pending(change(entries))
  })
}

///|
fn Observations::keep_pending(
  self : Observations,
  entries : Array[PendingReview],
) -> Unit raise @failure.TaskFailed {
  @store.save_json(
    self.pending_path(),
    Json::array(entries.map(PendingReview::to_json)),
    exclusive=false,
  )
}

///|
fn observation_root(env : @environment.Env) -> String {
  @path.join([env.state_root(), "cloud-observe"])
}

///|
fn Observations::locks_directory(self : Observations) -> String {
  @path.join([self.root, "locks"])
}

///|
fn Observations::pending_path(self : Observations) -> String {
  @path.join([self.root, "pending.json"])
}

///|
fn Observations::session_path(
  self : Observations,
  session_id : String,
) -> String {
  @path.join([self.root, "sessions", "\{session_id}.json"])
}

///|
fn Observations::opening_path(self : Observations, reviewer : String) -> String {
  @path.join([self.root, "opening", "\{short_hash(reviewer)}.json"])
}

///|
fn SessionPosition::to_json(self : SessionPosition) -> Json {
  object([
    ("sessionId", Json::string(self.session_id)),
    ("parentThreadId", Json::string(self.parent_thread_id)),
    (
      "baseline",
      object([
        ("uuid", text_or_null(self.baseline.uuid)),
        ("estimated", Json::boolean(self.baseline.estimated)),
        ("at", Json::string(self.baseline.at)),
      ]),
    ),
    ("cursor", text_or_null(self.cursor)),
    ("excluded", Json::array(self.excluded.map(Json::string))),
    ("taken", Json::array(self.taken.map(Json::string))),
  ])
}

///|
fn position_in(value : Json) -> SessionPosition? {
  guard value is Object(members) &&
    members.get("baseline") is Some(Object(baseline)) else {
    return None
  }
  guard members.get("sessionId") is Some(String(session_id)) &&
    members.get("parentThreadId") is Some(String(parent_thread_id)) else {
    return None
  }
  Some({
    session_id,
    parent_thread_id,
    baseline: {
      uuid: text_or_none(baseline.get("uuid")),
      estimated: baseline.get("estimated") is Some(True),
      at: text_or_none(baseline.get("at")).unwrap_or(""),
    },
    cursor: text_or_none(members.get("cursor")),
    excluded: strings_in(members.get("excluded")),
    taken: strings_in(members.get("taken")),
  })
}

///|
fn PendingReview::to_json(self : PendingReview) -> Json {
  object([
    ("parentThreadId", Json::string(self.parent_thread_id)),
    ("sessionId", text_or_null(self.session_id)),
    ("review", review_json(self.review)),
  ])
}

///|
fn pending_in(value : Json) -> Array[PendingReview] {
  let entries = []
  guard value is Array(items) else { return entries }
  for item in items {
    guard item is Object(members) &&
      members.get("review") is Some(Object(review)) else {
      continue
    }
    guard members.get("parentThreadId") is Some(String(parent_thread_id)) &&
      review.get("key") is Some(String(key)) &&
      review.get("reviewer") is Some(String(reviewer)) &&
      review.get("answer") is Some(String(answer)) else {
      continue
    }
    entries.push({
      parent_thread_id,
      session_id: text_or_none(members.get("sessionId")),
      review: {
        key,
        reviewer,
        verdict: text_or_none(review.get("verdict")),
        task_id: text_or_none(review.get("taskId")),
        head: text_or_none(review.get("head")),
        answer,
      },
    })
  }
  entries
}

///|
fn Opening::to_json(self : Opening) -> Json {
  object([
    ("key", Json::string(self.key)),
    ("text", Json::string(self.text)),
    ("sessionId", text_or_null(self.session_id)),
    ("showing", Json::boolean(self.showing)),
  ])
}
