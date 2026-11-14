///|
/// The outcomes this program writes itself; a bridge's answer may carry any other.
pub(all) enum CallOutcome {
  Done
  NotSent
  Unknown
  Unsupported
}

///|
fn CallOutcome::name(self : CallOutcome) -> String {
  match self {
    Done => "done"
    NotSent => "not_sent"
    Unknown => "unknown"
    Unsupported => "unsupported"
  }
}

///|
pub struct CallAnswer {
  // A newer bridge may write an outcome this program does not know, so the outcome stays the text the bridge wrote.
  outcome : String
  // A newer bridge may add a field, so every member other than the outcome is kept to reach the records unchanged.
  fields : Map[String, Json]
}

///|
pub fn CallAnswer::new(
  outcome : CallOutcome,
  fields : Array[(String, Json)],
) -> CallAnswer {
  { outcome: outcome.name(), fields: Map::from_array(fields), }
}

///|
pub fn CallAnswer::failed(outcome : CallOutcome, error~ : String) -> CallAnswer {
  CallAnswer::new(outcome, [("error", Json::string(error))])
}

///|
/// None unless the value is an object with a string outcome.
pub fn CallAnswer::of_json(value : Json) -> CallAnswer? {
  guard value is Object(members) &&
    members.get("outcome") is Some(String(outcome)) else {
    return None
  }
  let fields = Map::from_iter(
    members.iter().filter(pair => pair.0 != "outcome"),
  )
  Some({ outcome, fields, })
}

///|
pub fn CallAnswer::to_json(self : CallAnswer) -> Json {
  let members = { "outcome": Json::string(self.outcome) }

  for name, item in self.fields {
    members[name] = item
  }

  Json::object(members)
}

///|
pub fn CallAnswer::is_unsent(self : CallAnswer) -> Bool {
  // An outcome this program does not know may have acted, so only outcomes after which the bridge surely did not act let the call be sent again.
  self.outcome is ("not_sent" | "rejected" | "invalid" | "unsupported")
}

///|
fn not_sent(error : String) -> CallAnswer {
  CallAnswer::failed(NotSent, error~)
}

///|
fn unsupported(error : String) -> CallAnswer {
  CallAnswer::failed(Unsupported, error~)
}

///|
fn unknown(error : String) -> CallAnswer {
  CallAnswer::failed(Unknown, error~)
}
