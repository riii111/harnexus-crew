///|
/// A failure the command reports to the user as its message and exit code 1.
/// A boundary that must tell callers more, such as whether a call was sent, declares its own error type instead.
pub suberror TaskFailed {
  TaskFailed(String)
}

///|
pub fn TaskFailed::message(self : TaskFailed) -> String {
  let TaskFailed(message) = self
  message
}

///|
pub fn[T] fail(message : String) -> T raise TaskFailed {
  raise TaskFailed(message)
}
