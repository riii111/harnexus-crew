///|
/// The kinds of state this CLI keeps; the watch directory beside them belongs to pr-wake and is never read.
let owned_kinds : Array[String] = ["cloud-review", "launch", "review"]

///|
/// Every state file of the owned kinds, by path.
pub fn state_command(env : @environment.Env) -> Json raise @failure.TaskFailed {
  let listed : Array[(String, Json)] = []
  for path in list_state_paths(env.state_root()) {
    listed.push((path, @store.load(path)))
  }
  Json::object(Map::from_array(listed))
}

///|
fn list_state_paths(root : String) -> Array[String] raise @failure.TaskFailed {
  let paths : Array[String] = []
  for kind in owned_kinds {
    for key_path in list_subdirectories(@path.join([root, kind])) {
      for name in list_names(key_path) {
        if name.has_suffix(".json") {
          paths.push(@path.join([key_path, name]))
        }
      }
    }
  }
  paths.sort_by(String::lexical_compare)
  paths
}

///|
fn list_subdirectories(
  path : String,
) -> Array[String] raise @failure.TaskFailed {
  let subdirectories : Array[String] = []
  if @store.is_directory(path) {
    for name in list_names(path) {
      let child = @path.join([path, name])
      if @store.is_directory(child) {
        subdirectories.push(child)
      }
    }
  }
  subdirectories
}

///|
fn list_names(path : String) -> Array[String] raise @failure.TaskFailed {
  let names = @store.list_directory_if_exists(path) catch {
    failed => @failure.fail(failed.user_message())
  }
  names.unwrap_or([])
}
