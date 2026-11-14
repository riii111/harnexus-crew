///|
/// A member that may be absent or null, which the saved request tells apart.
pub enum OptionalText {
  Absent
  Null
  Text(String)
}

///|
fn add_optional(
  members : Map[String, Json],
  key : String,
  value : OptionalText,
) -> Unit {
  match value {
    Absent => ()
    Null => members[key] = Json::null()
    Text(text) => members[key] = Json::string(text)
  }
}

///|
pub enum WorkerAi {
  Claude
  Codex
}

///|
pub fn WorkerAi::name(self : WorkerAi) -> String {
  match self {
    Claude => "Claude"
    Codex => "Codex"
  }
}

///|
priv enum CompletionTarget {
  Implementation
  DraftPr
  Merge
}

///|
fn CompletionTarget::name(self : CompletionTarget) -> String {
  match self {
    Implementation => "implementation"
    DraftPr => "draft_pr"
    Merge => "merge"
  }
}
