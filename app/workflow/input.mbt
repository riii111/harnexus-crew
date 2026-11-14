///|
pub(all) struct LaunchInput {
  request : String
  model : String?
  thinking : String?
}

///|
pub(all) struct ReviewInput {
  request : String
  model : String?
  thinking : String?
  update_base : Bool
  /// `--recover discard`.
  discard_pending : Bool
  /// The file holding a message for the task's reviewer, in a Claude Code cloud session.
  ask : String?
}

///|
pub(all) struct StateInput {
  request : String?
}

///|
pub(all) struct ResolveInput {
  request : String
  /// True for `--sent`, false for `--not-sent`.
  sent : Bool
  thread_id : String?
}

///|
pub(all) struct NameInput {
  pr : String
}

///|
pub(all) struct WatchInput {
  dry_run : Bool
  prs : Array[String]
  release : String?
  status : Bool
  sender : Bool
  link : String?
}

///|
pub(all) struct CloudInput {
  link : String?
  prompt_file : String?
  project : String?
  title : String?
  model : String?
  thinking : String?
}
