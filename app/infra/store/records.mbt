///|
/// What a directory of one session's records holds.
/// state.json  : Confirmed state.
/// pending.json: A send whose result is unknown; blocks resending.
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
  let loaded = read_json_or_null(state_path)
  let state = check_record(loaded, state_path)
  let pending = check_record(read_json_or_null(pending_path), pending_path)
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
  lift_file_failure(() => prepare_directory(@path.dirname(path)))
  let content = data.stringify(indent=1)
  if !exclusive {
    lift_file_failure(() => write_atomic(path, content))
    return
  }
  let created = lift_file_failure(() => write_exclusive(path, content))
  if !created {
    @failure.fail("another harnexus-crew run is sending; inspect \{path}")
  }
}

///|
/// Reads a JSON file; a missing file reads as Null.
pub fn read_json_or_null(path : String) -> Json raise @failure.TaskFailed {
  match lift_file_failure(() => read_text_if_exists(path)) {
    None => Json::null()
    Some(text) =>
      @jsonio.parse(text) catch {
        _ => @failure.fail("\{path} is not valid JSON")
      }
  }
}

///|
/// Reads a regular JSON file, such as a request the user wrote.
pub fn read_regular_json(path : String) -> Json raise @failure.TaskFailed {
  let text = lift_file_failure(() => read_regular_text(path))
  @jsonio.parse(text) catch {
    _ => @failure.fail("\{path} is not valid JSON")
  }
}

///|
pub fn remove_record(path : String) -> Unit raise @failure.TaskFailed {
  lift_file_failure(() => remove_file(path))
}

///|
fn[T] lift_file_failure(
  work : () -> T raise FileFailed,
) -> T raise @failure.TaskFailed {
  work() catch {
    failed => @failure.fail(failed.user_message())
  }
}

///|
fn check_record(value : Json, path : String) -> Json? raise @failure.TaskFailed {
  match value {
    Null => None
    Object(members) if members.is_empty() => None
    Object(_) => Some(value)
    _ => @failure.fail("\{path} does not hold a JSON object")
  }
}
