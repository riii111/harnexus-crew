///|
/// A reviewer's chat as the chats file keeps it.
priv struct Chat {
  thread_id : String
  session : String?
}

///|
fn Chat::to_json(self : Chat) -> Json {
  object([
    ("threadId", Json::string(self.thread_id)),
    ("session", text_or_null(self.session)),
  ])
}

///|
fn chat_in(value : Json) -> Chat? {
  match value {
    String(thread_id) => Some({ thread_id, session: None, })
    Object(members) =>
      match members.get("threadId") {
        Some(String(thread_id)) =>
          Some({ thread_id, session: text_or_none(members.get("session")), })
        _ => None
      }
    _ => None
  }
}

///|
priv enum ReviewState {
  Sent
  /// A file may stand over a sent review, so the review is held.
  Held
  /// The review is absent or kept but not sent.
  Unsettled
}

///|
priv enum Claim {
  Claimed
  Taken
  Failed
}

///|
priv struct HistoryEntry {
  role : String
  text : String
  at : String
}

///|
const CHATS : String = "chats.json"

///|
const ASKED : String = "asked-"

///|
/// Made beside a review's file before it is sent, so of the adapters sharing the folder only one sends the review.
/// It is not a `.json` file, so it is never read as a conversation record.
const RESERVED : String = ".reserved"

///|
/// The folder of Cloud reviews and their chats, shared by every adapter and by the harnexus versions before the adapter.
priv struct ReviewStore {
  dir : String
  locks : String
}

///|
fn ReviewStore::new(dir : String, locks : String) -> ReviewStore {
  { dir, locks, }
}

///|
fn ReviewStore::read_chats(
  self : ReviewStore,
) -> Map[String, Chat] raise @failure.TaskFailed {
  let path = self.chats_path()
  let found : Map[String, Chat] = Map([])

  match read_object(path) {
    // An unreadable record may name an existing chat, so fail instead of treating it as empty and opening another.
    Unreadable => @failure.fail("\{path} is unreadable")
    Absent => ()
    Found(members) =>
      for reviewer, value in members {
        if chat_in(value) is Some(chat) {
          found[reviewer] = chat
        }
      }
  }

  found
}

///|
async fn ReviewStore::keep_chat(
  self : ReviewStore,
  reviewer : String,
  chat : Chat,
) -> Unit raise @failure.TaskFailed {
  // Every adapter takes this lock for the chats file, so two never overwrite each other's entries.
  @store.with_lock(self.locks, "chats", () => {
    let path = self.chats_path()
    let latest = match read_object(path) {
      Unreadable => @failure.fail("\{path} is unreadable")
      Absent => Map([])
      Found(members) => members
    }

    latest[reviewer] = chat.to_json()
    self.write(path, Json::object(latest))
  })
}

///|
fn ReviewStore::read_state(self : ReviewStore, key : String) -> ReviewState {
  match read_object(self.review_path(key)) {
    Absent => Unsettled
    Unreadable => Held
    Found(kept) =>
      if kept.get("sent") is Some(True) {
        Sent
      } else if is_unsent_review_file(kept, key) {
        Unsettled
      } else {
        Held
      }
  }
}

///|
/// Takes the review's reservation, which an adapter sharing the folder cannot take while it stands.
/// Only a reservation made here is ever removed.
fn ReviewStore::claim(self : ReviewStore, key : String) -> Claim {
  if (Ok(@store.prepare_directory(self.dir)) catch { e => Err(e) }) is Err(_) {
    return Failed
  }

  let path = self.reservation_path(key)
  let reserved = object([("reservedAt", Json::string(@store.now_iso()))])

  match
    (Ok(@store.write_exclusive(path, reserved.stringify())) catch {
      e => Err(e)
    }) {
    Ok(true) => Claimed
    Ok(false) => Taken
    // The reservation may be visible while its folder entry is lost in a crash, so it cannot allow a send; it was made here, so it is dropped.
    Err(@store.FileFailed(action=Sync, ..)) => {
      @store.remove_file(path) catch {
        _ => ()
      }
      Failed
    }
    Err(_) => Failed
  }
}

///|
fn ReviewStore::unclaim(self : ReviewStore, key : String) -> Unit {
  @store.remove_file(self.reservation_path(key)) catch {
    _ => ()
  }
}

///|
fn ReviewStore::keep_unsent(
  self : ReviewStore,
  review : @host.CloudReview,
) -> Unit raise @failure.TaskFailed {
  self.write(self.review_path(review.key), review_json(review))
}

///|
fn ReviewStore::mark_sent(
  self : ReviewStore,
  review : @host.CloudReview,
  thread_id : String?,
) -> Unit raise @failure.TaskFailed {
  guard review_json(review) is Object(members) else { return }

  members["sent"] = Json::boolean(true)
  members["threadId"] = text_or_null(thread_id)
  members["shownAt"] = Json::string(@store.now_iso())
  self.write(self.review_path(review.key), Json::object(members))
}

///|
fn ReviewStore::note_ask(
  self : ReviewStore,
  thread_id : String,
  text : String,
) -> Unit raise @failure.TaskFailed {
  let name = "\{ASKED}\{@env.now()}-\{@store.new_uuid()}.json"
  self.write(
    @path.join([self.dir, name]),
    object([
      ("threadId", Json::string(thread_id)),
      ("shownAt", Json::string(@store.now_iso())),
      ("asked", Json::string(text)),
    ]),
  )
}

///|
/// The reviews shown in a reviewer's chat and the messages sent from it, oldest first, as the chat's history.
fn ReviewStore::read_history(
  self : ReviewStore,
  thread_id : String,
) -> Array[HistoryEntry] {
  let names = match
    (Ok(@store.list_directory_if_exists(self.dir)) catch { e => Err(e) }) {
    Ok(Some(names)) => names
    _ => return []
  }

  let shown : Array[Shown] = []

  for name in names {
    guard name.has_suffix(".json") && name != CHATS else { continue }
    guard read_object(@path.join([self.dir, name])) is Found(kept) else {
      continue
    }
    guard kept.get("threadId") is Some(String(named)) &&
      named == thread_id &&
      kept.get("shownAt") is Some(String(at)) else {
      continue
    }

    if name.has_prefix(ASKED) {
      if kept.get("asked") is Some(String(asked)) {
        shown.push({
          at,
          asked: true,
          entries: [
            { role: "user", text: asked, at, },
            { role: "assistant", text: @host.REVIEW_ASK_SENT, at, },
          ],
        })
      }

      continue
    }

    let key = name[:name.length() - 5].to_owned()
    if review_in(key, Some(kept)) is Some(review) {
      shown.push({
        at,
        asked: false,
        entries: [{ role: "assistant", text: @host.review_text(review), at, }],
      })
    }
  }

  // A message is sent after the review it answers, so within one millisecond the review comes first rather than in the order the folder lists them.
  let order = shown.mapi((index, entry) => (index, entry))

  order.sort_by((a, b) => {
    let by_time = String::lexical_compare(a.1.at, b.1.at)
    if by_time != 0 {
      by_time
    } else if a.1.asked != b.1.asked {
      if a.1.asked {
        1
      } else {
        -1
      }
    } else {
      a.0 - b.0
    }
  })

  let history = []

  for pair in order {
    history.append(pair.1.entries)
  }

  history
}

///|
fn ReviewStore::chats_path(self : ReviewStore) -> String {
  @path.join([self.dir, CHATS])
}

///|
fn ReviewStore::review_path(self : ReviewStore, key : String) -> String {
  @path.join([self.dir, "\{key}.json"])
}

///|
fn ReviewStore::reservation_path(self : ReviewStore, key : String) -> String {
  @path.join([self.dir, "\{key}\{RESERVED}"])
}

///|
fn ReviewStore::write(
  self : ReviewStore,
  path : String,
  value : Json,
) -> Unit raise @failure.TaskFailed {
  lift_file_failure(() => @store.prepare_directory(self.dir))
  lift_file_failure(() => @store.write_atomic(path, value.stringify()))
}

///|
priv struct Shown {
  at : String
  asked : Bool
  entries : Array[HistoryEntry]
}

///|
fn resolve_reviews_directory(
  env : @environment.Env,
) -> String raise @failure.TaskFailed {
  // To share records with harnexus, keep them beside its state file.
  @path.join([
    @path.dirname(@environment.resolve_harnexus_state_path(env)),
    "cloud-reviews",
  ])
}

///|
fn review_json(review : @host.CloudReview) -> Json {
  object([
    ("key", Json::string(review.key)),
    ("reviewer", Json::string(review.reviewer)),
    ("verdict", text_or_null(review.verdict)),
    ("taskId", text_or_null(review.task_id)),
    ("head", text_or_null(review.head)),
    ("answer", Json::string(review.answer)),
  ])
}

///|
fn review_in(key : String, kept : Map[String, Json]?) -> @host.CloudReview? {
  guard kept is Some(members) else { return None }
  guard members.get("reviewer") is Some(String(reviewer)) &&
    members.get("answer") is Some(String(answer)) else {
    return None
  }

  Some({
    key,
    reviewer,
    verdict: text_or_none(members.get("verdict")),
    task_id: text_or_none(members.get("taskId")),
    head: text_or_none(members.get("head")),
    answer,
  })
}

///|
/// A file written before the review was sent, by harnexus or the CLI; anything else may stand over a sent review.
fn is_unsent_review_file(kept : Map[String, Json], key : String) -> Bool {
  let text_or_absent = (name : String) => {
    match kept.get(name) {
      None | Some(Null) | Some(String(_)) => true
      _ => false
    }
  }

  kept.get("key") is Some(String(named)) &&
  named == key &&
  kept.get("reviewer") is Some(String(_)) &&
  kept.get("answer") is Some(String(_)) &&
  text_or_absent("verdict") &&
  text_or_absent("taskId") &&
  text_or_absent("head") &&
  !kept.contains("sent") &&
  !kept.contains("threadId") &&
  !kept.contains("shownAt")
}

///|
priv enum ReadObject {
  Absent
  Unreadable
  Found(Map[String, Json])
}

///|
fn read_object(path : String) -> ReadObject {
  match (Ok(@store.read_text_if_exists(path)) catch { e => Err(e) }) {
    Err(_) => Unreadable
    Ok(None) => Absent
    Ok(Some(text)) =>
      match (Ok(@jsonio.parse(text)) catch { e => Err(e) }) {
        Ok(Object(members)) => Found(members)
        _ => Unreadable
      }
  }
}
