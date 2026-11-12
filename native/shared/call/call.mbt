///|
/// What harnexus call protocol 1 answers, plus `Unsupported` for a bridge that does not offer the protocol or the tool, to which nothing was sent.
pub enum CallOutcome {
  Done
  // Protocol 1 never answers this; it is kept for a bridge that still does.
  ToolError
  NotSent
  Rejected
  Invalid
  Unknown
  ModelMismatch
  FirstTurnRefused
  ChatNotOpened
  Unsupported
}

///|
pub fn CallOutcome::name(self : CallOutcome) -> String {
  match self {
    Done => "done"
    ToolError => "tool_error"
    NotSent => "not_sent"
    Rejected => "rejected"
    Invalid => "invalid"
    Unknown => "unknown"
    ModelMismatch => "model_mismatch"
    FirstTurnRefused => "first_turn_refused"
    ChatNotOpened => "chat_not_opened"
    Unsupported => "unsupported"
  }
}

///|
/// None for a name the bridge may send that this program does not know.
pub fn CallOutcome::from_name(name : String) -> CallOutcome? {
  match name {
    "done" => Some(Done)
    "tool_error" => Some(ToolError)
    "not_sent" => Some(NotSent)
    "rejected" => Some(Rejected)
    "invalid" => Some(Invalid)
    "unknown" => Some(Unknown)
    "model_mismatch" => Some(ModelMismatch)
    "first_turn_refused" => Some(FirstTurnRefused)
    "chat_not_opened" => Some(ChatNotOpened)
    "unsupported" => Some(Unsupported)
    _ => None
  }
}

///|
/// Outcomes after which the bridge surely did not act, so the call may be sent again.
pub fn CallOutcome::is_unsent(self : CallOutcome) -> Bool {
  match self {
    NotSent | Rejected | Invalid | Unsupported => true
    Done
    | ToolError
    | Unknown
    | ModelMismatch
    | FirstTurnRefused
    | ChatNotOpened => false
  }
}

///|
/// A bridge's answer.
/// The outcome stays the text the bridge wrote and every other member is kept, so an outcome or field added by a newer bridge reaches the records unchanged.
pub struct CallAnswer {
  outcome : String
  fields : Map[String, Json]
}

///|
pub fn CallAnswer::failed(outcome : CallOutcome, error~ : String) -> CallAnswer {
  { outcome: outcome.name(), fields: { "error": Json::string(error) }, }
}

///|
pub fn CallAnswer::of_json(value : Json) -> CallAnswer raise @jsonio.JsonError {
  let fields = @jsonio.Fields::from_json(value, context="bridge answer")
  let outcome = fields.take_string("outcome")
  { outcome, fields: fields.rest(), }
}

///|
pub fn CallAnswer::to_json(self : CallAnswer) -> Json {
  @jsonio.object_with_extra(
    [("outcome", Json::string(self.outcome))],
    self.fields,
  )
}

///|
/// An outcome this program does not know is not unsent: it may have acted, so the call is never sent again on its account.
pub fn CallAnswer::is_unsent(self : CallAnswer) -> Bool {
  match CallOutcome::from_name(self.outcome) {
    Some(outcome) => outcome.is_unsent()
    None => false
  }
}
