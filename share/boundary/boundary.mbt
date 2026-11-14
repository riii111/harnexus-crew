///|
/// `connected` is false when the connection itself failed, so the line was never written.
/// When it is true, whether the line was written is unknown.
pub(all) suberror LineExchangeFailed {
  LineExchangeFailed(
    path~ : String,
    code~ : String?,
    connected~ : Bool,
    message~ : String
  )
}

///|
/// Why a process ended; anything but `Exit` means its result is unknown.
pub(all) enum ProcessEnd {
  Exit
  Timeout
  OutputLimit
}

///|
pub fn ProcessEnd::name(self : ProcessEnd) -> String {
  match self {
    Exit => "exit"
    Timeout => "timeout"
    OutputLimit => "output-limit"
  }
}

///|
pub(all) struct ProcessRun {
  status : Int32
  stdout : String
  stderr : String
  ended : ProcessEnd
}

///|
/// `started` is false only when the process never started, the only case in which it surely did not run.
pub(all) suberror ProcessRunFailed {
  ProcessRunFailed(started~ : Bool, message~ : String)
}

///|
/// Any exit status is a result; the caller decides what a failure means.
pub(all) struct CommandOutput {
  status : Int32
  stdout : String
  stderr : String
}

///|
/// `code` is the error code Node attaches to the failure, such as `ENOENT`.
pub(all) suberror CommandFailed {
  CommandFailed(command~ : String, message~ : String, code~ : String?)
}
