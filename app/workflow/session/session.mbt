///|
priv struct Ports {
  /// Sends an App operation as the caller's thread: caller, tool, arguments.
  call : async (String, String, Map[String, Json]) -> @bridge.CallAnswer noraise
  /// Writes a record; with `exclusive` the record must not exist yet.
  save : (String, Json, Bool) -> Unit raise @failure.TaskFailed
}

///|
type MakeConfirmedState = (String, Map[String, Json], Json, Map[String, Json]?) -> Map[
  String,
  Json,
] raise @failure.TaskFailed

///|
priv struct Session {
  ports : Ports
  state_path : String
  pending_path : String
  history_path : String
  /// The content of `state.json` as read, so a later read can tell whether another run wrote it in between.
  loaded : Json
  state : Map[String, Json]?
  mut pending : Map[String, Json]?
  /// Makes the state a confirmed send leaves: the thread, the pending record, what was sent, and the state so far.
  confirmed : MakeConfirmedState
  /// The flat fields `state --request` shows for this kind of session.
  summarize : (Map[String, Json]?, Map[String, Json]?) -> Map[String, Json]
}

///|
fn Session::open(
  directory : String,
  ports : Ports,
  confirmed~ : MakeConfirmedState,
  summarize~ : (Map[String, Json]?, Map[String, Json]?) -> Map[String, Json],
) -> Session raise @failure.TaskFailed {
  let records = @store.read_records(directory)
  {
    ports,
    state_path: records.state_path,
    pending_path: records.pending_path,
    history_path: "\{directory}/history.json",
    loaded: records.loaded,
    state: object_of(records.state),
    pending: object_of(records.pending),
    confirmed,
    summarize,
  }
}

///|
async fn Session::send(
  self : Session,
  caller : String,
  tool : String,
  args : Map[String, Json],
  extra : Array[(String, Json)],
) -> Json raise @failure.TaskFailed {
  self.check_idle()
  let record : Map[String, Json] = {
    "status": Json::string("sending"),
    "tool": Json::string(tool),
    "arguments": Json::object(args),
  }

  for pair in extra {
    record[pair.0] = pair.1
  }

  // To prevent resending an operation whose answer was lost, create its pending record exclusively before sending.
  (self.ports.save)(self.pending_path, Json::object(record), true)

  if @store.read_json_or_null(self.state_path) != self.loaded {
    @store.remove_record(self.pending_path)
    @failure.fail(
      "another \{@environment.NAME} run changed the state; rerun to check it",
    )
  }

  let answer = (self.ports.call)(caller, tool, args)
  let outcome = answer.outcome
  let answered = value_of(answer.fields, "threadId")
  let thread = if truthy(answered) {
    answered
  } else {
    value_of(args, "threadId")
  }

  fn keep_for_resolve(
    status : String,
    extra : Array[(String, Json)],
  ) -> Unit raise @failure.TaskFailed {
    record["status"] = Json::string(status)
    record["threadId"] = thread
    record["answer"] = answer.to_json()

    for pair in extra {
      record[pair.0] = pair.1
    }

    (self.ports.save)(self.pending_path, Json::object(record), false)
  }

  if outcome == "done" {
    // The thread exists, so a failed record is kept for resolve rather than released.
    errdefer keep_for_resolve("unknown", [])
    return self.confirm(record, thread, Some(answer))
  }

  // Either way the thread exists but never ran, so it is kept for resolve rather than sent again.
  let refusal : Array[(String, Json)]? = match outcome {
    "model_mismatch" =>
      Some([
        ("expected", value_of(answer.fields, "expected")),
        ("actual", value_of(answer.fields, "actual")),
      ])
    "first_turn_refused" =>
      Some([("reason", value_of(answer.fields, "reason"))])
    _ => None
  }

  if refusal is Some(refusal) {
    keep_for_resolve("refused", refusal)
    self.pending = Some(record)
    self.check_idle()
  }

  let text = answer.to_json().stringify()

  if answer.is_unsent() {
    @store.remove_record(self.pending_path)
    @failure.fail("\{tool} was not sent: \{text}")
  }

  keep_for_resolve("unknown", [])
  @failure.fail(
    "\{tool} result is unknown (\{text}); never resend. Ask the user to check the App",
  )
}

///|
/// Settles the pending send as the user found it: sent, with the thread it went to, or not sent.
fn Session::resolve(
  self : Session,
  sent : Bool,
  thread : String?,
) -> Json raise @failure.TaskFailed {
  guard self.pending is Some(pending) else {
    @failure.fail("nothing is pending")
  }

  if !sent {
    if value_of(pending, "status") is String("refused") {
      let history = @store.read_json_or_null(self.history_path)
      let kept = match history {
        Array(items) => items.copy()
        _ => []
      }

      kept.push(Json::object(pending))
      (self.ports.save)(self.history_path, Json::array(kept), false)
    }

    @store.remove_record(self.pending_path)
    return Json::object({
      "released": value_of(pending, "tool"),
      "status": value_of(pending, "status"),
    })
  }

  if value_of(pending, "status") is String("refused") {
    @failure.fail("a refused first turn never ran; use --not-sent")
  }

  let named = match thread {
    Some(id) if id != "" => Json::string(id)
    _ => value_of(pending, "threadId")
  }

  self.confirm(pending, named, None)
}

///|
fn Session::confirm(
  self : Session,
  record : Map[String, Json],
  thread : Json,
  answer : @bridge.CallAnswer?,
) -> Json raise @failure.TaskFailed {
  if !truthy(thread) {
    @failure.fail(
      "thread ID is unknown; check the App, then resolve --sent --thread-id",
    )
  }

  let args = match value_of(record, "arguments") {
    Object(args) => args
    _ => {}
  }

  let answered = fn(key : String) -> Json {
    match answer {
      Some(answer) => value_of(answer.fields, key)
      None => Json::null()
    }
  }
  let expected = Json::object({
    "model": value_of(args, "model"),
    "effort": value_of(args, "thinking"),
  })
  let actual = Json::object({
    "model": answered("model"),
    "effort": answered("effort"),
  })
  let sent = Json::object({
    "tool": value_of(record, "tool"),
    "prompt": value_of(args, "prompt"),
    "expected": expected,
    "actual": actual,
    "workspace": value_of(record, "workspace"),
    "answer": match answer {
      Some(answer) => answer.to_json()
      None => Json::null()
    },
  })

  let id = match thread {
    String(text) => @request.check_chat_id(text, "threadId")
    _ => @failure.fail("threadId must be a nonempty single-line string")
  }

  let next = (self.confirmed)(id, record, sent, self.state)
  (self.ports.save)(self.state_path, Json::object(next), false)
  @store.remove_record(self.pending_path)
  // A message to an existing thread that asked for no model or effort learns neither, so nulls would only mislead.
  let unasked = value_of(record, "tool") is String("send_message_to_thread") &&
    !args.contains("model") &&
    !args.contains("thinking")
  let shown : Map[String, Json] = {
    "tool": value_of(record, "tool"),
    "threadId": thread,
  }

  if !unasked {
    shown["model"] = answered("model")
    shown["effort"] = answered("effort")
    shown["expected"] = expected
  }

  shown["state"] = Json::string(self.state_path)
  Json::object(shown)
}

///|
/// The session as flat fields, with null for anything unknown, so a reader never has to guess where a value is nested.
fn Session::show(self : Session) -> Json raise @failure.TaskFailed {
  let refused = @store.read_json_or_null(self.history_path)
  let state = state_json(self.state)
  let sent = @jsonio.field(state, "sent")

  // A state without kept settings holds them in its create send, so they are read from there.
  let settings = match @jsonio.field(state, "settings") {
    Null => sent_settings(sent)
    kept => kept
  }

  let pending = state_json(self.pending)
  let shown = (self.summarize)(self.state, self.pending)
  shown["requested"] = settings_of(@jsonio.field(settings, "requested"))
  shown["actual"] = settings_of(@jsonio.field(settings, "actual"))
  shown["pending"] = @jsonio.field(pending, "status")
  shown["pendingThreadId"] = @jsonio.field(pending, "threadId")
  shown["statePath"] = Json::string(self.state_path)
  shown["prompt"] = @jsonio.field(sent, "prompt")
  shown["refusedThreadIds"] = Json::array(
    match refused {
      Array(items) => items.map(item => @jsonio.field(item, "threadId"))
      _ => []
    },
  )
  Json::object(shown)
}

///|
fn Session::check_idle(self : Session) -> Unit raise @failure.TaskFailed {
  check_idle(self.pending)
}

///|
fn check_idle(pending : Map[String, Json]?) -> Unit raise @failure.TaskFailed {
  guard pending is Some(pending) else { return }
  let thread = @jsonio.as_text(value_of(pending, "threadId"))

  if value_of(pending, "status") is String("refused") {
    let reason = value_of(pending, "reason")
    if truthy(reason) {
      @failure.fail(
        "the bridge refused the first turn of thread \{thread}: \{@jsonio.as_text(reason)}; fix the cause, then resolve --not-sent",
      )
    }

    let expected = value_of(pending, "expected")
    let actual = value_of(pending, "actual")
    @failure.fail(
      "thread \{thread} refused its first turn: \{refusal_text(expected, actual)}; fix the model, then resolve --not-sent",
    )
  }

  @failure.fail(
    "previous \{@jsonio.as_text(value_of(pending, "tool"))} ended as \{@jsonio.as_text(value_of(pending, "status"))}; never resend. Ask the user to check the App, then run resolve --sent or --not-sent",
  )
}

///|
fn refusal_text(expected : Json, actual : Json) -> String {
  // The app answers a refusal with the settings it checked; anything else is shown as it came.
  match (expected, actual) {
    (Object(_), Object(_)) =>
      @host.refusal_of(turn_settings_of(expected), turn_settings_of(actual))
    _ =>
      "expected \{@jsonio.as_text(expected)}, actual \{@jsonio.as_text(actual)}"
  }
}

///|
fn turn_settings_of(settings : Json) -> @host.TurnSettings {
  fn text_of(value : Json) -> String? {
    match value {
      String(text) => Some(text)
      _ => None
    }
  }

  {
    model: text_of(@jsonio.field(settings, "model")),
    effort: text_of(@jsonio.field(settings, "effort")),
  }
}

///|
fn object_of(record : Json?) -> Map[String, Json]? {
  match record {
    Some(Object(members)) => Some(members)
    _ => None
  }
}

///|
fn state_json(state : Map[String, Json]?) -> Json {
  match state {
    Some(members) => Json::object(members)
    None => Json::null()
  }
}
