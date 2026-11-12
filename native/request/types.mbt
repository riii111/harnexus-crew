///|
/// A member that may be absent or null, which the saved request tells apart.
pub enum OptionalText {
  Absent
  Null
  Text(String)
}

///|
pub fn OptionalText::text(self : OptionalText) -> String? {
  match self {
    Text(text) => Some(text)
    Absent | Null => None
  }
}

///|
pub enum CompletionTarget {
  Implementation
  DraftPr
  Merge
}

///|
pub fn CompletionTarget::name(self : CompletionTarget) -> String {
  match self {
    Implementation => "implementation"
    DraftPr => "draft_pr"
    Merge => "merge"
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
