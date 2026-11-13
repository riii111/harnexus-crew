///|
/// What harnexus call protocol 1 answers, plus `Unsupported` for a bridge that does not offer the protocol or the tool, to which nothing was sent.
pub(all) enum CallOutcome {
  Done
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
    Done | Unknown | ModelMismatch | FirstTurnRefused | ChatNotOpened => false
  }
}

///|
/// A bridge's answer.
/// The outcome stays the text the bridge wrote and every other member is kept, so an outcome or field added by a newer bridge reaches the records unchanged.
pub struct CallAnswer {
  outcome : String
  fields : Map[String, Json]
  // How many of `fields` the bridge wrote before the outcome, so the answer prints in the order it came.
  priv outcome_at : Int32
}

///|
/// An answer made here, with the outcome first as the bridge writes it.
pub fn CallAnswer::new(
  outcome : CallOutcome,
  fields : Array[(String, Json)],
) -> CallAnswer {
  let members = Map([])
  for pair in fields {
    let (name, item) = pair
    members[name] = item
  }
  { outcome: outcome.name(), fields: members, outcome_at: 0, }
}

///|
pub fn CallAnswer::failed(outcome : CallOutcome, error~ : String) -> CallAnswer {
  CallAnswer::new(outcome, [("error", Json::string(error))])
}

///|
pub fn CallAnswer::of_json(value : Json) -> CallAnswer raise @jsonio.JsonError {
  let fields = @jsonio.Fields::from_json(value, context="bridge answer")
  let outcome_at = outcome_position(value)
  let outcome = fields.take_string("outcome")
  { outcome, fields: fields.rest(), outcome_at, }
}

///|
fn outcome_position(value : Json) -> Int32 {
  match value {
    Object(pairs) => {
      let mut at = 0
      for name, _ in pairs {
        if name == "outcome" {
          break
        }
        at += 1
      }
      at
    }
    _ => 0
  }
}

///|
pub fn CallAnswer::to_json(self : CallAnswer) -> Json {
  let members = Map([])
  let mut at = 0
  for name, item in self.fields {
    if at == self.outcome_at {
      members["outcome"] = Json::string(self.outcome)
    }
    members[name] = item
    at += 1
  }
  if at <= self.outcome_at {
    members["outcome"] = Json::string(self.outcome)
  }
  Json::object(members)
}

///|
/// An outcome this program does not know is not unsent: it may have acted, so the call is never sent again on its account.
pub fn CallAnswer::is_unsent(self : CallAnswer) -> Bool {
  match CallOutcome::from_name(self.outcome) {
    Some(outcome) => outcome.is_unsent()
    None => false
  }
}
