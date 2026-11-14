///|
const PROTOCOL_VERSION : Int32 = 1

///|
const REVIEW_CHAT_MODEL : String = "claude-sonnet-5-5"

///|
const MODE_REFUSED : String = "harnexus-crew serves only a bridge in write mode; set \"mode\": \"write\" in harnexus's connection.json."

///|
/// What the bridge answered a request, as harnexus's adapter protocol 1 names it.
priv struct Answer {
  outcome : String
  members : Map[String, Json]
}

///|
fn Answer::field(self : Answer, name : String) -> Json? {
  self.members.get(name)
}

///|
fn Answer::reason(self : Answer) -> String? {
  text_or_none(self.members.get("reason"))
}

///|
priv struct Deps {
  adapter_id : String
  send : async (String) -> Unit noraise
  store : ReviewStore
  observations : Observations
  /// Where the locks every adapter on the machine shares are kept.
  locks : String
  /// The empty project reviewers run in, where a reviewer's chat is opened.
  review_home : String
  /// Called with what the adapter could not do, for its own log; never sent to the bridge.
  log : async (Array[(String, Json)]) -> Unit noraise
}

///|
priv struct Job {
  run : async () -> Unit noraise
  done : @aqueue.Queue[Unit]?
}

///|
priv enum Handling {
  Handled
  /// Work to run in its own task.
  Later(async () -> Unit noraise)
}

///|
priv struct Delivery {
  outcome : String
  thread_id : String?
}

///|
/// One connection to a harnexus bridge: it takes the reviews Cloud sessions print, keeps what it has seen of each session, and shows each review once in its reviewer's chat.
priv struct Adapter {
  deps : Deps
  /// Set once the bridge's hello is accepted; until then nothing is taken or sent for it.
  mut writing : Bool
  mut ready : Bool
  mut next_id : Int32
  /// Set once the bridge has closed its end, after which nothing is sent to it.
  mut closed : Bool
  unanswered : Map[String, @aqueue.Queue[Answer]]
  /// Events change the shared records one at a time, in the order they came.
  jobs : @aqueue.Queue[Job]
}

///|
fn Adapter::new(deps : Deps) -> Adapter {
  {
    deps,
    writing: false,
    ready: false,
    next_id: 0,
    closed: false,
    unanswered: Map([]),
    jobs: @aqueue.Queue(kind=Unbounded),
  }
}

///|
fn Adapter::accept(self : Adapter, raw : String) -> Handling {
  let line = match (Ok(@jsonio.parse(raw)) catch { e => Err(e) }) {
    Ok(Object(_) as parsed) => parsed
    _ => return self.log_later([("step", Json::string("line_invalid"))])
  }
  guard field(line, "v") is Some(Number(version, ..)) &&
    version == PROTOCOL_VERSION.to_double() else {
    return self.log_later([("step", Json::string("line_invalid"))])
  }
  match field(line, "type") {
    Some(String("hello")) => self.accept_hello(line)
    Some(String("ready")) => {
      self.ready = true
      Later(() => self.take_ready(line))
    }
    // To keep the end of input from overtaking a response, handle responses immediately instead of spawning a task.
    Some(String("response")) => {
      self.complete_request(line)
      Handled
    }
    Some(String("request")) =>
      if field(line, "op") is Some(String("history")) {
        Later(() => self.answer_history(line))
      } else {
        Handled
      }
    Some(String("event")) =>
      match field(line, "event") {
        Some(String("session_records")) =>
          Later(() => {
            self.run_in_order(() => {
              self.take_records(line)
              self.drain()
            })
          })
        Some(String("turn")) => Later(() => self.take_turn(line))
        Some(String("conversation_bound")) => Later(() => self.take_bound(line))
        _ => Handled
      }
    other => {
      let step = [("step", Json::string("line_unknown"))]
      if other is Some(kind) {
        step.push(("type", kind))
      }
      self.log_later(step)
    }
  }
}

///|
fn Adapter::accept_hello(self : Adapter, line : Json) -> Handling {
  let offered = match field(line, "versions") {
    Some(Array(versions)) =>
      versions
      .iter()
      .any(version => {
        version is Number(number, ..) && number == PROTOCOL_VERSION.to_double()
      })
    _ => false
  }
  if !offered {
    return self.log_later([("step", Json::string("version_refused"))])
  }
  // An observing bridge refuses every request that shows a review, so only a writing one is served.
  if !(field(line, "mode") is Some(String("write"))) {
    return self.log_later([
      ("step", Json::string("mode_refused")),
      ("message", Json::string(MODE_REFUSED)),
    ])
  }
  self.writing = true
  Later(() => self.greet())
}

///|
fn Adapter::log_later(
  self : Adapter,
  entry : Array[(String, Json)],
) -> Handling {
  Later(() => (self.deps.log)(entry))
}

///|
async fn Adapter::log_failure(
  self : Adapter,
  step : String,
  failed : @failure.TaskFailed,
) -> Unit noraise {
  (self.deps.log)([
    ("step", Json::string(step)),
    ("message", Json::string(failed.message())),
  ])
}

///|
async fn Adapter::take_ready(self : Adapter, line : Json) -> Unit noraise {
  let bindings = field(line, "bindings")
  self.adopt_bridge_bindings(bindings)
  self.run_in_order(() => self.post_missed_openings(bindings))
  if field(line, "conflicts") is Some(Array(conflicts)) &&
    conflicts.length() > 0 {
    (self.deps.log)([
      ("step", Json::string("binding_conflicts")),
      ("threads", Json::array(conflicts)),
    ])
  }
  self.run_in_order(() => self.drain())
}

///|
async fn Adapter::take_records(self : Adapter, event : Json) -> Unit noraise {
  if !self.writing {
    return
  }
  let session_id = text_member_or_empty(event, "sessionId")
  let records = objects_in(field(event, "records"))
  let known = self.deps.observations.read_position(session_id) catch {
    failed => {
      self.log_failure("position_unreadable", failed)
      return
    }
  }
  let (position, from) = match known {
    None => first_position(event, session_id, records)
    Some(position) => {
      // A cursor not found again may mean lost records, so every record is read again and the kept keys keep out what was taken.
      let at = match position.cursor {
        None => -1
        Some(cursor) => index_of_uuid(records, cursor)
      }
      (position, at + 1)
    }
  }
  let seen : Map[String, Bool] = Map([])
  for key in position.excluded {
    seen[key] = true
  }
  for key in position.taken {
    seen[key] = true
  }
  let fresh = @host.reviews_in(records, from~).filter(review => {
    !seen.contains(review.key)
  })
  let parent = text_member_or_empty(event, "parentThreadId")
  let entries : Array[PendingReview] = fresh.map(review => {
    parent_thread_id: parent,
    session_id: Some(session_id),
    review,
  })
  // Every review is queued before the position moves past it; a failure leaves the position, so the records are read again.
  if entries.length() > 0 {
    self.deps.observations.add_pending(entries) catch {
      failed => {
        self.log_failure("pending_unwritable", failed)
        return
      }
    }
  }
  position.taken.append(fresh.map(review => review.key))
  if @host.uuid_of(records.last()) is Some(uuid) {
    position.cursor = Some(uuid)
  }
  position.parent_thread_id = parent
  // A crash before the position is kept must read the records again, so the bridge is told only once it is kept.
  let kept = Ok(self.deps.observations.keep_position(position)) catch {
    e => Err(e)
  }
  if kept is Ok(_) && text_member(event, "eventId") is Some(event_id) {
    self.send_line([
      ("type", Json::string("observed")),
      ("eventId", Json::string(event_id)),
    ])
  }
}

///|
async fn Adapter::take_turn(self : Adapter, event : Json) -> Unit noraise {
  let turn_id = text_member_or_empty(event, "turnId")
  let conversation = text_member_or_empty(event, "conversationId")
  if !self.writing {
    self.end_turn(
      turn_id,
      None,
      failed=Some("harnexus-crew does not serve this bridge."),
    )
    return
  }
  if field(event, "kind") is Some(String("opened")) {
    let ended = Ref(false)
    ignore(
      self.show_opening(conversation, text => {
        self.end_turn(turn_id, Some(text))
        ended.val = true
        true
      }),
    )
    if !ended.val {
      self.end_turn(turn_id, None)
    }
    // Reviews of the same reviewer waited for this chat's first review to be shown.
    self.enqueue(() => self.drain())
    return
  }
  self.ask_reviewer(
    turn_id,
    text_member_or_empty(event, "threadId"),
    conversation,
    text_member_or_empty(event, "text"),
  )
}

///|
async fn Adapter::take_bound(self : Adapter, event : Json) -> Unit noraise {
  let reviewer = text_member_or_empty(event, "conversationId")
  let thread_id = text_member_or_empty(event, "threadId")
  let chats = self.deps.store.read_chats() catch { _ => return }
  if chats.get(reviewer) is Some(chat) && chat.thread_id == thread_id {
    return
  }
  let session = self.read_opening_session(reviewer)
  self.deps.store.keep_chat(reviewer, { thread_id, session, }) catch {
    _ => ()
  }
}

///|
async fn Adapter::answer_history(self : Adapter, line : Json) -> Unit noraise {
  let thread_id = text_member_or_empty(line, "threadId")
  let entries = self.deps.store
    .read_history(thread_id)
    .map(entry => {
      object([
        ("role", Json::string(entry.role)),
        ("text", Json::string(entry.text)),
        ("at", Json::string(entry.at)),
      ])
    })
  let response = [("type", Json::string("response"))]
  if field(line, "id") is Some(id) {
    response.push(("id", id))
  }
  response.push(("outcome", Json::string("done")))
  response.push(("entries", Json::array(entries)))
  self.send_line(response)
}

///|
fn Adapter::complete_request(self : Adapter, line : Json) -> Unit {
  guard line is Object(members) else { return }
  guard members.get("id") is Some(String(id)) else { return }
  guard self.unanswered.get(id) is Some(waiting) else { return }
  self.unanswered.remove(id)
  let outcome = text_member(line, "outcome").unwrap_or("unknown")
  ignore(waiting.try_put({ outcome, members, }) catch { _ => false })
}

///|
fn Adapter::close_input(self : Adapter) -> Unit {
  // An unanswered request may have acted, so block later sends and settle pending answers as unknown.
  self.closed = true
  for _, waiting in self.unanswered {
    ignore(waiting.try_put(answer_of("unknown")) catch { _ => false })
  }
  self.unanswered.clear()
}

///|
async fn Adapter::run_jobs(self : Adapter) -> Unit noraise {
  while true {
    let job = match (Ok(self.jobs.get()) catch { e => Err(e) }) {
      Ok(job) => job
      Err(_) => break
    }
    (job.run)()
    if job.done is Some(done) {
      ignore(done.try_put(()) catch { _ => false })
    }
  }
}

///|
async fn Adapter::finish(self : Adapter) -> Unit noraise {
  self.run_in_order(() => ())
  self.jobs.close()
}

///|
async fn Adapter::run_in_order(
  self : Adapter,
  work : async () -> Unit noraise,
) -> Unit noraise {
  let done : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Unbounded)
  ignore(
    self.jobs.try_put({ run: work, done: Some(done), }) catch {
      _ => false
    },
  )
  done.get() catch {
    _ => ()
  }
}

///|
fn Adapter::enqueue(self : Adapter, work : async () -> Unit noraise) -> Unit {
  ignore(self.jobs.try_put({ run: work, done: None, }) catch { _ => false })
}

///|
async fn Adapter::adopt_bridge_bindings(
  self : Adapter,
  bindings : Json?,
) -> Unit noraise {
  guard self.writing && bindings is Some(Array(items)) else { return }
  let chats = self.deps.store.read_chats() catch { _ => return }
  for binding in items {
    guard text_member(binding, "conversationId") is Some(reviewer) &&
      text_member(binding, "threadId") is Some(thread_id) else {
      continue
    }
    let kept = chats.get(reviewer)
    if kept is Some(chat) && chat.thread_id == thread_id {
      continue
    }
    if kept is Some(_) {
      (self.deps.log)([
        ("step", Json::string("binding_differs")),
        ("conversationId", Json::string(reviewer)),
      ])
      continue
    }
    let session = self.read_opening_session(reviewer)
    // The chats file stays the record of which chat shows which reviewer, so a binding the bridge saved while this adapter was stopped is written to it.
    self.deps.store.keep_chat(reviewer, { thread_id, session, }) catch {
      failed => self.log_failure("chat_unwritable", failed)
    }
  }
}

///|
async fn Adapter::post_missed_openings(
  self : Adapter,
  bindings : Json?,
) -> Unit noraise {
  guard self.writing && bindings is Some(Array(items)) else { return }
  // A chat created while disconnected missed its opening review, so post the saved review.
  for binding in items {
    guard text_member(binding, "conversationId") is Some(reviewer) else {
      continue
    }
    ignore(
      self.show_opening(reviewer, text => {
        let posted = self.post_text(reviewer, text)
        posted.outcome == "done" || posted.outcome == "unknown"
      }),
    )
  }
}

///|
/// Serializes a chat's first review and report whether it may have been shown.
async fn Adapter::show_opening(
  self : Adapter,
  reviewer : String,
  show : async (String) -> Bool noraise,
) -> Bool noraise {
  @store.with_lock(self.deps.locks, "opening-\{lock_name(reviewer)}", () => {
    let observations = self.deps.observations
    let record = match
      (Ok(observations.read_opening(reviewer)) catch { e => Err(e) }) {
      Ok(Some(found)) => found
      _ => return false
    }
    // The previous connection may have ended after showing the review, so never show one already marked as showing again.
    if record.showing {
      (self.deps.log)([
        ("step", Json::string("opening_maybe_shown")),
        ("reviewer", Json::string(reviewer)),
        ("key", Json::string(record.key)),
      ])
      observations.drop_opening(reviewer) catch {
        _ => ()
      }
      return false
    }
    if (Ok(observations.keep_opening(reviewer, { ..record, showing: true, })) catch {
        e => Err(e)
      })
      is Err(_) {
      return false
    }
    let shown = show(record.text)
    // A post surely not carried out may be repeated, so its record is put back as it was for the next connection.
    if shown {
      observations.drop_opening(reviewer) catch {
        _ => ()
      }
    } else {
      observations.keep_opening(reviewer, record) catch {
        _ => ()
      }
    }
    shown
  }) catch {
    _ => false
  }
}

///|
fn Adapter::read_opening_session(
  self : Adapter,
  reviewer : String,
) -> String? noraise {
  match
    (Ok(self.deps.observations.read_opening(reviewer)) catch { e => Err(e) }) {
    Ok(Some(record)) => record.session_id
    _ => None
  }
}

///|
async fn Adapter::end_turn(
  self : Adapter,
  turn_id : String,
  text : String?,
  failed~ : String? = None,
) -> Unit noraise {
  if text is Some(text) {
    self.send_line([
      ("type", Json::string("turn_output")),
      ("turnId", Json::string(turn_id)),
      ("text", Json::string(text)),
      ("phase", Json::string("final")),
    ])
  }
  let end = [
    ("type", Json::string("turn_end")),
    ("turnId", Json::string(turn_id)),
    (
      "status",
      Json::string(if failed is None { "completed" } else { "failed" }),
    ),
  ]
  if failed is Some(message) {
    end.push(("message", Json::string(message)))
  }
  self.send_line(end)
}

///|
/// A message the user wrote in a reviewer's chat goes to the Cloud session that ran the reviewer, which passes it on.
async fn Adapter::ask_reviewer(
  self : Adapter,
  turn_id : String,
  thread_id : String,
  reviewer : String,
  text : String,
) -> Unit noraise {
  let session = match (Ok(self.deps.store.read_chats()) catch { e => Err(e) }) {
    Ok(chats) =>
      match chats.get(reviewer) {
        Some(chat) => chat.session
        None => None
      }
    Err(_) => None
  }
  guard session is Some(session) else {
    self.end_turn(turn_id, Some(@host.REVIEW_ASK_UNROUTED))
    return
  }
  let sent = self.request("cloud_send", [
    ("sessionId", Json::string(session)),
    ("text", Json::string(@host.reviewer_ask(reviewer, text))),
  ])
  if sent.outcome == "done" {
    self.deps.store.note_ask(thread_id, text) catch {
      _ => ()
    }
    self.end_turn(turn_id, Some(@host.REVIEW_ASK_SENT))
  } else if sent.outcome == "rejected" && sent.reason() == Some("not_linked") {
    self.end_turn(turn_id, Some(@host.REVIEW_ASK_UNROUTED))
  } else if sent.outcome == "unknown" {
    self.end_turn(turn_id, None, failed=Some(@host.REVIEW_ASK_UNKNOWN))
  } else {
    let reason = match sent.field("reason") {
      Some(reason) => ": \{@jsonio.as_text(reason)}"
      None => ""
    }
    self.end_turn(
      turn_id,
      None,
      failed=Some("The message was not sent (\{sent.outcome}\{reason})."),
    )
  }
}

///|
/// Tries every waiting review once, keeping those surely not shown for the next try.
async fn Adapter::drain(self : Adapter) -> Unit noraise {
  if !self.writing || !self.ready {
    return
  }
  let waiting = self.deps.observations.read_pending() catch {
    failed => {
      self.log_failure("pending_unreadable", failed)
      return
    }
  }
  let settled : Map[String, Bool] = Map([])
  for entry in waiting {
    if !should_retry(self.deliver(entry)) {
      settled[entry.review.key] = true
    }
  }
  // Only the reviews settled here leave the list, so one another adapter added meanwhile stays.
  self.deps.observations.remove_pending(settled) catch {
    failed => self.log_failure("pending_unwritable", failed)
  }
}

///|
async fn Adapter::deliver(
  self : Adapter,
  entry : PendingReview,
) -> String noraise {
  @store.with_lock(self.deps.locks, lock_name(entry.review.reviewer), () => {
    self.deliver_locked(entry)
  }) catch {
    _ => "not_kept"
  }
}

///|
async fn Adapter::deliver_locked(
  self : Adapter,
  entry : PendingReview,
) -> String noraise {
  let review = entry.review
  let store = self.deps.store
  match store.read_state(review.key) {
    Sent => return "done"
    Held => return "held"
    _ => ()
  }
  match store.claim(review.key) {
    Taken =>
      return if store.read_state(review.key) is Sent {
        "done"
      } else {
        "reserved"
      }
    Failed => return "not_kept"
    Claimed => ()
  }
  if (Ok(store.keep_unsent(review)) catch { e => Err(e) }) is Err(_) {
    store.unclaim(review.key)
    return "not_kept"
  }
  let chats = store.read_chats() catch {
    _ => {
      store.unclaim(review.key)
      return "held"
    }
  }
  let text = @host.review_text(review)
  // While a chat's first review waits for its first turn, a later review of the same reviewer waits too, so it is neither shown first nor opens another chat.
  let recorded = self.deps.observations.read_opening(review.reviewer) catch {
    _ => {
      store.unclaim(review.key)
      return "awaiting_chat"
    }
  }
  if recorded is Some(opening) && opening.key != review.key {
    store.unclaim(review.key)
    return "awaiting_chat"
  }
  let mut shown : Delivery? = None
  if chats.get(review.reviewer) is Some(chat) {
    let posted = self.post_text(review.reviewer, text)
    if !(posted.outcome == "rejected" && posted.reason() == Some("unbound")) {
      shown = Some({ outcome: posted.outcome, thread_id: Some(chat.thread_id), })
    }
    // A message from the chat goes to the session that ran this review, which a chat kept from before may not name yet.
    if (posted.outcome == "done" || posted.outcome == "unknown") &&
      entry.session_id is Some(session) &&
      chat.session != Some(session) {
      store.keep_chat(review.reviewer, {
        thread_id: chat.thread_id,
        session: entry.session_id,
      }) catch {
        failed => self.log_failure("chat_unwritable", failed)
      }
    }
  }
  let delivery = match shown {
    Some(delivery) => delivery
    None => self.open_chat(entry, text)
  }
  if delivery.outcome == "done" || delivery.outcome == "unknown" {
    store.mark_sent(review, delivery.thread_id) catch {
      _ =>
        (self.deps.log)([
          ("step", Json::string("sent_not_recorded")),
          ("key", Json::string(review.key)),
        ])
    }
  } else {
    store.unclaim(review.key)
  }
  delivery.outcome
}

///|
async fn Adapter::open_chat(
  self : Adapter,
  entry : PendingReview,
  text : String,
) -> Delivery noraise {
  let review = entry.review
  let listed = self.request("list_projects", [
    ("callerThreadId", Json::string(entry.parent_thread_id)),
  ])
  if listed.outcome != "done" {
    return { outcome: "not_sent", thread_id: None, }
  }
  guard self.review_project(listed.field("result")) is Some(project_id) else {
    return { outcome: "no_project", thread_id: None, }
  }
  // To avoid creating another chat after an unknown result, record its opening review before sending the create request.
  let recorded = Ok(
    self.deps.observations.keep_opening(review.reviewer, {
      key: review.key,
      text,
      session_id: entry.session_id,
      showing: false,
    }),
  ) catch {
    e => Err(e)
  }
  if recorded is Err(_) {
    return { outcome: "not_kept", thread_id: None, }
  }
  let title = "\{@host.CLOUD_MARK} Review｜\{review.task_id.unwrap_or(review.reviewer)}"
  let created = self.request("create_conversation", [
    ("conversationId", Json::string(review.reviewer)),
    ("callerThreadId", Json::string(entry.parent_thread_id)),
    (
      "arguments",
      object([
        (
          "target",
          object([
            ("type", Json::string("project")),
            ("projectId", Json::string(project_id)),
            ("environment", object([("type", Json::string("local"))])),
          ]),
        ),
        ("title", Json::string(title)),
        ("model", Json::string(REVIEW_CHAT_MODEL)),
      ]),
    ),
  ])
  let thread_id = text_or_none(created.field("threadId"))
  // An unknown create may still bind the chat and open its first turn later, so only a create surely not carried out lets the record go.
  if created.outcome != "done" && created.outcome != "unknown" {
    self.deps.observations.drop_opening(review.reviewer) catch {
      _ => ()
    }
  }
  if thread_id is Some(thread_id) {
    self.deps.store.keep_chat(review.reviewer, {
      thread_id,
      session: entry.session_id,
    }) catch {
      _ => ()
    }
  }
  // A conversation the bridge already binds opens no turn, so the review is posted to its chat instead.
  if created.outcome == "done" && created.field("existing") is Some(True) {
    self.deps.observations.drop_opening(review.reviewer) catch {
      _ => ()
    }
    let posted = self.post_text(review.reviewer, text)
    return { outcome: posted.outcome, thread_id, }
  }
  { outcome: created.outcome, thread_id, }
}

///|
fn Adapter::review_project(self : Adapter, result : Json?) -> String? {
  @bridge.find_project_id(result, self.deps.review_home)
}

///|
async fn Adapter::greet(self : Adapter) -> Unit noraise {
  // Old reviewer chats are declared from the chats file, the record of which chat shows which reviewer, so the bridge binds them again.
  self.send_line([
    ("type", Json::string("hello")),
    ("adapterId", Json::string(self.deps.adapter_id)),
    ("bindings", Json::array(self.read_declared_bindings())),
  ])
}

///|
async fn Adapter::read_declared_bindings(self : Adapter) -> Array[Json] noraise {
  let chats = self.deps.store.read_chats() catch {
    failed => {
      self.log_failure("chats_unreadable", failed)
      return []
    }
  }
  let bindings = []
  for reviewer, chat in chats {
    bindings.push(
      object([
        ("conversationId", Json::string(reviewer)),
        ("threadId", Json::string(chat.thread_id)),
      ]),
    )
  }
  bindings
}

///|
async fn Adapter::request(
  self : Adapter,
  op : String,
  fields : Array[(String, Json)],
) -> Answer noraise {
  if self.closed {
    return answer_of("not_sent", reason=Some("closed"))
  }
  self.next_id += 1
  let id = "harnexus-crew-\{self.next_id}"
  let answered : @aqueue.Queue[Answer] = @aqueue.Queue(kind=Unbounded)
  self.unanswered[id] = answered
  self.send_line(
    [
      ("type", Json::string("request")),
      ("id", Json::string(id)),
      ("op", Json::string(op)),
      ..fields,
    ],
  )
  match (Ok(answered.get()) catch { e => Err(e) }) {
    Ok(answer) => answer
    Err(_) => answer_of("unknown")
  }
}

///|
async fn Adapter::post_text(
  self : Adapter,
  reviewer : String,
  text : String,
) -> Answer noraise {
  self.request("post", [
    ("conversationId", Json::string(reviewer)),
    ("text", Json::string(text)),
  ])
}

///|
async fn Adapter::send_line(
  self : Adapter,
  line : Array[(String, Json)],
) -> Unit noraise {
  let framed = [("v", Json::number(PROTOCOL_VERSION.to_double())), ..line]
  (self.deps.send)(object(framed).stringify())
}

///|
fn first_position(
  event : Json,
  session_id : String,
  records : Array[Json],
) -> (SessionPosition, Int32) {
  let linked = field(event, "phase") is Some(String("linked"))
  // A linked session is measured from the record the chat was linked at; a session first seen continuing is measured from what the app was last shown, which a restarted bridge may only estimate.
  let base = if linked {
    match field(event, "linkedAt") {
      Some(String(at)) => Some(at)
      _ => @host.uuid_of(records.last())
    }
  } else {
    text_or_none(field(event, "shownBefore"))
  }
  let found = match base {
    Some(uuid) => index_of_uuid(records, uuid)
    None => -1
  }
  // A base not among the records leaves every review in them out, so nothing from before the link is opened.
  let end = match base {
    None => 0
    Some(_) => if found == -1 { records.length() } else { found + 1 }
  }
  let position : SessionPosition = {
    session_id,
    parent_thread_id: text_member_or_empty(event, "parentThreadId"),
    baseline: { uuid: base, estimated: !linked, at: @store.now_iso(), },
    cursor: if end > 0 {
      @host.uuid_of(Some(records[end - 1]))
    } else {
      None
    },
    excluded: @host.reviews_in(records, from=0, to=end).map(review => review.key),
    taken: [],
  }
  (position, end)
}

///|
fn index_of_uuid(records : Array[Json], uuid : String) -> Int32 {
  for index, record in records {
    if @host.uuid_of(Some(record)) == Some(uuid) {
      return index
    }
  }
  -1
}

///|
fn lock_name(reviewer : String) -> String {
  "reviewer-\{short_hash(reviewer)}"
}

///|
fn answer_of(outcome : String, reason~ : String? = None) -> Answer {
  let members = Map([])
  if reason is Some(reason) {
    members["reason"] = Json::string(reason)
  }
  { outcome, members, }
}

///|
fn should_retry(outcome : String) -> Bool {
  // To avoid showing a review twice after an unknown result, retry only outcomes that prove it was not shown.
  match outcome {
    "not_sent"
    | "awaiting_chat"
    | "rejected"
    | "invalid"
    | "no_project"
    | "not_kept"
    | "held" => true
    _ => false
  }
}
