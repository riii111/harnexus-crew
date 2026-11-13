///|
/// What a directory of one session's records holds.
/// `state.json` is what was confirmed; `pending.json` is a send whose result is unknown and blocks any resend.
pub struct Records {
  state_path : String
  pending_path : String
  /// The content of `state.json` as read, Null when it is missing, so a later read can tell whether another run wrote it in between.
  loaded : Json
  /// The members of `state.json`, or None when it is missing or empty.
  state : Json?
  /// The members of `pending.json`, or None when it is missing or empty.
  pending : Json?
}

///|
pub fn read_records(directory : String) -> Records raise @failure.TaskFailed {
  let state_path = "\{directory}/state.json"
  let pending_path = "\{directory}/pending.json"
  let loaded = load(state_path)
  let state = as_record(loaded, state_path)
  let pending = as_record(load(pending_path), pending_path)
  { state_path, pending_path, loaded, state, pending, }
}

///|
/// Saves a record as `JSON.stringify(data, null, 1)` would, so the files read alike in either version.
/// With `exclusive`, the record is created only if none exists, and another run having created it is a failure.
pub fn save_json(
  path : String,
  data : Json,
  exclusive~ : Bool,
) -> Unit raise @failure.TaskFailed {
  io(() => prepare_directory(dirname(path)))
  let content = stringify_indented(data)
  if !exclusive {
    io(() => write_atomic(path, content))
    return
  }
  let created = io(() => write_exclusive(path, content))
  if !created {
    @failure.fail("another harnexus-crew run is sending; inspect \{path}")
  }
}

///|
/// Reads a JSON file; a missing file reads as Null.
pub fn load(path : String) -> Json raise @failure.TaskFailed {
  match io(() => read_text_if_exists(path)) {
    None => Json::null()
    Some(text) =>
      @jsonio.parse(text) catch {
        _ => @failure.fail("\{path} is not valid JSON")
      }
  }
}

///|
/// Removes a record; one that is already missing counts as removed.
pub fn remove_record(path : String) -> Unit raise @failure.TaskFailed {
  io(() => remove_file(path))
}

///|
/// Runs a file operation and reports its failure the way the user sees it.
fn[T] io(work : () -> T raise FileFailed) -> T raise @failure.TaskFailed {
  work() catch {
    failed => @failure.fail(failed.user_message())
  }
}

///|
/// A record is a non-empty JSON object; an absent or empty value reads as none.
fn as_record(value : Json, path : String) -> Json? raise @failure.TaskFailed {
  match value {
    Object(members) if members.is_empty() => None
    Object(_) => Some(value)
    _ if not_truthy(value) => None
    _ => @failure.fail("\{path} does not hold a JSON object")
  }
}

///|
/// The values Python and JS count as false, which decide whether state recorded by either version is present.
fn not_truthy(value : Json) -> Bool {
  match value {
    Null | False => true
    Number(number, ..) => number == 0.0
    String(text) => text.length() == 0
    Array(items) => items.is_empty()
    _ => false
  }
}
