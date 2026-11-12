///|
/// One Cloud session's chat as `export-links` and `import-links` carry it.
/// A `thread_id` of None is a chat whose opening never reported back, so it is never opened again.
priv struct CloudLink {
  session_id : String
  thread_id : String?
  reserved_at : String
}

///|
fn CloudLink::to_json(self : CloudLink) -> Json {
  object([
    ("sessionId", Json::string(self.session_id)),
    ("threadId", optional_text(self.thread_id)),
    ("reservedAt", Json::string(self.reserved_at)),
  ])
}

///|
const SHAPE : String = "expected {\"version\":1,\"links\":[{\"sessionId\",\"threadId\",\"reservedAt\"}]} with each session once"

///|
fn is_link_key(name : String) -> Bool {
  name == "sessionId" || name == "threadId" || name == "reservedAt"
}

///|
fn chats_directory(env : @environment.Env) -> String {
  @path.join([env.state_root(), "cloud-chats"])
}

///|
/// A file the TypeScript build's `cloud` command wrote: `startedAt` while the chat was being opened, `openedAt` once it was.
/// A file naming neither time is dated now, since the reservation stands either way.
fn link_of(session_id : String, kept : Json) -> CloudLink? {
  guard kept is Object(members) else { return None }
  guard members.get("threadId") is Some(thread) else { return None }
  let thread_id = match thread {
    Null => None
    String(text) if text != "" => Some(text)
    _ => return None
  }
  let reserved_at = match members.get("openedAt") {
    Some(String(opened)) => opened
    _ =>
      match members.get("startedAt") {
        Some(String(started)) => started
        _ => @store.now_iso()
      }
  }
  Some({ session_id, thread_id, reserved_at, })
}

///|
/// Every session the `cloud` command opened or began to open, refusing a file it cannot read rather than leaving it out.
fn export_links(env : @environment.Env) -> Json raise @failure.TaskFailed {
  let dir = chats_directory(env)
  let names = io(() => @store.list_directory_if_exists(dir)).unwrap_or([])
  names.sort_by(@text.compare_utf16)
  let links = []
  for name in names {
    guard name.has_suffix(".json") else { continue }
    let session_id = name[:name.length() - 5].to_owned()
    guard is_session_id(session_id) else { continue }
    let path = @path.join([dir, name])
    match link_of(session_id, @store.load(path)) {
      Some(link) => links.push(link.to_json())
      None => @failure.fail("\{path} is not a Cloud chat record")
    }
  }
  object([("version", Json::number(1.0)), ("links", Json::array(links))])
}

///|
fn links_in(value : Json) -> Array[CloudLink]? {
  guard value is Object(root) else { return None }
  guard root.get("version") is Some(Number(version, ..)) && version == 1.0 else {
    return None
  }
  guard root.get("links") is Some(Array(items)) else { return None }
  let links = []
  let sessions : Map[String, Bool] = Map([])
  for item in items {
    guard item is Object(members) else { return None }
    for name, _ in members {
      if !is_link_key(name) {
        return None
      }
    }
    guard members.get("sessionId") is Some(String(session)) &&
      is_session_id(session) &&
      !sessions.contains(session) else {
      return None
    }
    guard members.get("reservedAt") is Some(String(reserved)) && reserved != "" else {
      return None
    }
    let named : Map[String, Json] = Map([])
    if members.get("threadId") is Some(thread) {
      named["threadId"] = thread
    }
    named["startedAt"] = Json::string(reserved)
    match link_of(session, Json::object(named)) {
      Some(link) => links.push(link)
      None => return None
    }
    sessions[session] = true
  }
  Some(links)
}

///|
/// Writes links back as the `cloud` command kept them, for a return to it.
/// A chat already recorded is never lost or replaced by another, and a reservation is kept until a chat is named for it.
fn import_links(
  env : @environment.Env,
  value : Json,
) -> Json raise @failure.TaskFailed {
  guard links_in(value) is Some(links) else { @failure.fail(SHAPE) }
  let dir = chats_directory(env)
  let conflicts = []
  let mut written = 0
  let mut kept = 0
  for link in links {
    let path = @path.join([dir, "\{link.session_id}.json"])
    let before = @store.load(path)
    let existing = if before is Null {
      None
    } else {
      link_of(link.session_id, before)
    }
    if !(before is Null) && existing is None {
      conflicts.push(link.session_id)
      continue
    }
    if existing is Some(current) &&
      (current.thread_id == link.thread_id || link.thread_id is None) {
      kept += 1
      continue
    }
    if existing is Some({ thread_id: Some(_), .. }) {
      conflicts.push(link.session_id)
      continue
    }
    let record = match link.thread_id {
      None =>
        object([
          ("threadId", Json::null()),
          ("startedAt", Json::string(link.reserved_at)),
        ])
      Some(thread_id) =>
        object([
          ("threadId", Json::string(thread_id)),
          ("openedAt", Json::string(link.reserved_at)),
        ])
    }
    @store.save_json(path, record, exclusive=false)
    written += 1
  }
  if conflicts.length() > 0 {
    let sessions = conflicts.join(", ")
    @failure.fail(
      "kept the chats already recorded for \{sessions}, which the links name differently; wrote \{written}",
    )
  }
  object([
    ("written", Json::number(written.to_double())),
    ("kept", Json::number(kept.to_double())),
  ])
}
