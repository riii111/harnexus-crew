///|
/// The kinds of state this CLI keeps; the watch directory beside them belongs to pr-wake and is never read.
let owned_kinds : Array[String] = ["cloud-review", "launch", "review"]

///|
/// Every state file of the owned kinds, by path.
pub fn state_command(env : @environment.Env) -> Json raise @failure.TaskFailed {
  let listed : Array[(String, Json)] = []
  for path in state_paths(env.state_root()) {
    listed.push((path, @store.read_json_or_null(path)))
  }
  Json::object(Map::from_array(listed))
}

///|
fn state_paths(root : String) -> Array[String] raise @failure.TaskFailed {
  let paths : Array[String] = []
  if @store.is_directory(root) {
    for kind in owned_kinds {
      let kind_path = @path.join([root, kind])
      if !@store.is_directory(kind_path) {
        continue
      }
      for key in names_in(kind_path) {
        let key_path = @path.join([kind_path, key])
        if !@store.is_directory(key_path) {
          continue
        }
        for name in names_in(key_path) {
          if name.has_suffix(".json") {
            paths.push(@path.join([key_path, name]))
          }
        }
      }
    }
  }
  paths.sort_by(String::lexical_compare)
  paths
}

///|
fn names_in(path : String) -> Array[String] raise @failure.TaskFailed {
  let names = @store.list_directory_if_exists(path) catch {
    failed => @failure.fail(failed.user_message())
  }
  names.unwrap_or([])
}
