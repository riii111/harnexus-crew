///|
/// What a request check asks of the file system.
/// These are the only reads a check makes; a test passes fixed answers.
pub(all) struct FileProbe {
  path_exists : async (String) -> Bool noraise
  is_directory : async (String) -> Bool noraise
  /// The real path of an existing path, or its absolute form when it cannot be resolved.
  real_path_or_self : async (String) -> String noraise
}

///|
pub fn FileProbe::of_machine() -> FileProbe {
  {
    path_exists: path => @store.path_exists(path),
    is_directory: path => @store.is_directory(path),
    real_path_or_self: path => @store.real_path_or_self(path),
  }
}
