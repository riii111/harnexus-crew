///|
/// One request line that did not get an answer.
/// `connected` is false when the connection itself failed, so the line was never written.
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
/// A process that did not settle.
/// `started` is false only when it never started, which is the only case in which it surely did not run.
pub(all) suberror ProcessRunFailed {
  ProcessRunFailed(started~ : Bool, message~ : String)
}

///|
/// What a short command printed.
/// Any exit status is a result; the caller decides what a failure means.
pub(all) struct CommandOutput {
  status : Int32
  stdout : String
  stderr : String
}

///|
/// A command that could not start or ran past its timeout.
pub(all) suberror CommandFailed {
  CommandFailed(command~ : String, message~ : String)
}
