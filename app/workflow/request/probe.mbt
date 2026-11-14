///|
pub(all) struct FileProbe {
  path_exists : async (String) -> Bool noraise
  is_directory : async (String) -> Bool noraise
  /// The real path of an existing path, or its absolute form when it cannot be resolved.
  resolve_real_path_or_self : async (String) -> String noraise
}

///|
pub fn FileProbe::of_machine() -> FileProbe {
  {
    path_exists: path => @store.path_exists(path),
    is_directory: path => @store.is_directory(path),
    resolve_real_path_or_self: path => @store.resolve_real_path_or_self(path),
  }
}
