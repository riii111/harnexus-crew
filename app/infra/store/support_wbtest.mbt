///|
async fn in_scratch(
  body : async (String) -> Unit raise Error,
) -> Unit raise Error {
  let directory = @testkit.scratch("store")
  errdefer @async.protect_from_cancel(() => @testkit.remove_tree(directory))
  body(directory)
  @testkit.remove_tree(directory)
}

///|
/// The message a record or lock operation fails with, or "" when it succeeds.
fn task_failure(work : () -> Unit raise @failure.TaskFailed) -> String {
  try {
    work()
    ""
  } catch {
    failed => failed.message()
  }
}

///|
fn read_text(path : String) -> String raise {
  match read_text_if_exists(path) {
    Some(text) => text
    None => fail("\{path} does not exist")
  }
}

///|
fn list_names(path : String) -> Array[String] raise {
  guard list_directory_if_exists(path) is Some(names) else {
    fail("\{path} is not a directory")
  }
  names.sort_by(String::lexical_compare)
  names
}

///|
/// A process id no process has: above Linux's default limit of 4194304.
let dead_pid : Double = 4195303.0
