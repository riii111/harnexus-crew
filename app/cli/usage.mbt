///|
let feedback_hint : String = "To report a bug, open an issue at https://github.com/riii111/taskctl/issues with the command you ran and its output."

///|
fn usage_of(commands : Array[String], name : String) -> String {
  let buffer = StringBuilder()
  buffer.write_string("usage:\n")
  for command in commands {
    buffer.write_string("  \{name} \{usage_line(command)}\n")
  }
  buffer.to_string()
}

///|
fn help_run(usage : String) -> @run.CommandRun {
  { code: 0, stdout: "\{usage}\{feedback_hint}\n", stderr: "", }
}

///|
fn usage_error_run(
  usage : String,
  name : String,
  message : String,
) -> @run.CommandRun {
  { code: 2, stdout: "", stderr: "\{usage}\{name}: \{message}\n", }
}

///|
fn usage_line(command : String) -> String {
  match command {
    "launch" => "launch --request REQUEST [--model MODEL] [--thinking THINKING]"
    "review" =>
      "review --request REQUEST [--model MODEL] [--thinking THINKING] [--update-base] [--recover discard] [--ask FILE]"
    "state" => "state [--request REQUEST]"
    "resolve" =>
      "resolve --request REQUEST (--sent | --not-sent) [--thread-id THREAD_ID]"
    "name" => "name --pr PR"
    "watch" =>
      "watch [--dry-run [--pr PR]... | --release PR | --status | --sender | --link PR]"
    "environment" => "environment"
    "check" => "check"
    "cloud" =>
      "cloud (--link SESSION_OR_URL | --prompt-file FILE) [--project PROJECT_ID] [--title TITLE] [--model MODEL] [--thinking THINKING]"
    other => other
  }
}
