///|
#borrow(path)
extern "C" fn rmdir_raw(path : Bytes) -> Int32 = "harnexus_store_rmdir"

///|
/// A new empty directory under the temporary directory, for one test to fill.
fn scratch() -> String {
  let base = @env.get_env_var("TMPDIR").unwrap_or("/tmp")
  let directory = @path.join([base, "hx-store-\{new_uuid()}"])
  prepare_directory(directory) catch {
    failed => abort(failed.user_message())
  }
  directory
}

///|
fn remove_tree(path : String) -> Unit {
  let names = list_directory_if_exists(path) catch { _ => None }
  for name in names.unwrap_or([]) {
    let child = "\{path}/\{name}"
    if is_directory(child) {
      remove_tree(child)
    } else {
      ignore(unlink_path(child))
    }
  }
  match @sys.c_string(path) {
    Some(bytes) => ignore(rmdir_raw(bytes))
    None => ()
  }
}

///|
/// Runs `body` in a scratch directory and removes the directory afterwards.
fn in_scratch(body : (String) -> Unit raise Error) -> Unit raise Error {
  let directory = scratch()
  defer remove_tree(directory)
  body(directory)
}

///|
/// The message a file operation fails with, or "" when it succeeds.
fn file_failure(work : () -> Unit raise FileFailed) -> String {
  try {
    work()
    ""
  } catch {
    failed => failed.user_message()
  }
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
  read_text_if_exists(path).unwrap()
}

///|
fn names_in(path : String) -> Array[String] raise {
  let names = list_directory_if_exists(path).unwrap()
  names.sort_by(String::lexical_compare)
  names
}

///|
/// A process id no process has: above Linux's default limit of 4194304.
let dead_pid : Double = 4195303.0
