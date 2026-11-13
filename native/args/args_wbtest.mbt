///|
fn opt(value : String?) -> String {
  value.unwrap_or("(none)")
}

///|
fn outcome(command : String, rest : Array[String]) -> String {
  try {
    match parse_command(command, rest[:]) {
      Help => "help"
      Run(Launch(a)) =>
        "launch request=\{a.request} model=\{opt(a.model)} thinking=\{opt(a.thinking)}"
      Run(Review(a)) =>
        "review request=\{a.request} update_base=\{a.update_base} discard=\{a.discard_pending} ask=\{opt(a.ask)}"
      Run(State(a)) => "state request=\{opt(a.request)}"
      Run(Resolve(a)) =>
        "resolve request=\{a.request} sent=\{a.sent} thread=\{opt(a.thread_id)}"
      Run(Name(a)) => "name pr=\{a.pr}"
      Run(Watch(a)) =>
        "watch dry_run=\{a.dry_run} prs=\{a.prs.join(",")} release=\{opt(a.release)} status=\{a.status} sender=\{a.sender} link=\{opt(a.link)}"
      Run(Cloud(a)) =>
        "cloud link=\{opt(a.link)} prompt_file=\{opt(a.prompt_file)} project=\{opt(a.project)}"
      Run(Environment) => "environment"
      Run(Check) => "check"
    }
  } catch {
    UsageError(message) => "usage: " + message
  }
}

///|
test "options are read with a value after a space or after an equals sign" {
  inspect(
    outcome("launch", ["--request", "a"]),
    content="launch request=a model=(none) thinking=(none)",
  )
  inspect(
    outcome("launch", ["--request=a=b", "--model", "-"]),
    content="launch request=a=b model=- thinking=(none)",
  )
  inspect(
    outcome("launch", ["--request", "a", "--request", "b", "--request="]),
    content="launch request= model=(none) thinking=(none)",
  )
}

///|
test "help wins over a missing option but not over a bad one" {
  inspect(outcome("launch", ["-h"]), content="help")
  inspect(outcome("launch", ["--help"]), content="help")
  inspect(outcome("launch", ["-hh"]), content="usage: Unknown option '-hh'")
  inspect(
    outcome("launch", ["-h", "--nope"]),
    content="usage: Unknown option '--nope'",
  )
}

///|
test "an unknown option or a stray argument is refused" {
  inspect(
    outcome("check", ["--nope"]),
    content="usage: Unknown option '--nope'",
  )
  inspect(
    outcome("check", ["--nope=1"]),
    content="usage: Unknown option '--nope'",
  )
  inspect(outcome("check", ["-x"]), content="usage: Unknown option '-x'")
  inspect(outcome("check", ["-hx"]), content="usage: Unknown option '-hx'")
  inspect(outcome("check", ["-h=1"]), content="usage: Unknown option '-h=1'")
  inspect(outcome("check", ["--=x"]), content="usage: Unknown option '--=x'")
  inspect(outcome("check", ["---x"]), content="usage: Unknown option '---x'")
  inspect(outcome("check", ["--req"]), content="usage: Unknown option '--req'")
  inspect(
    outcome("check", ["pos"]),
    content="usage: Unexpected argument 'pos'. This command does not take positional arguments",
  )
  inspect(
    outcome("check", ["-"]),
    content="usage: Unexpected argument '-'. This command does not take positional arguments",
  )
  inspect(
    outcome("check", [""]),
    content="usage: Unexpected argument ''. This command does not take positional arguments",
  )
}

///|
test "a lone double dash ends the options and nothing may follow it" {
  inspect(outcome("check", ["--"]), content="check")
  inspect(
    outcome("check", ["--", "--"]),
    content="usage: Unexpected argument '--'. This command does not take positional arguments",
  )
  inspect(
    outcome("check", ["--", "--help"]),
    content="usage: Unexpected argument '--help'. This command does not take positional arguments",
  )
  inspect(
    outcome("launch", ["--request", "a", "--"]),
    content="launch request=a model=(none) thinking=(none)",
  )
}

///|
test "a value that looks like an option is ambiguous, and a missing one is named" {
  let ambiguous = "usage: Option '--request' argument is ambiguous.\nDid you forget to specify the option argument for '--request'?\nTo specify an option argument starting with a dash use '--request=-XYZ'."
  inspect(outcome("launch", ["--request", "--model"]), content=ambiguous)
  inspect(outcome("launch", ["--request", "-1"]), content=ambiguous)
  inspect(outcome("launch", ["--request", "--"]), content=ambiguous)
  inspect(
    outcome("launch", ["--request"]),
    content="usage: Option '--request <value>' argument missing",
  )
  inspect(
    outcome("launch", ["--request=--x"]),
    content="launch request=--x model=(none) thinking=(none)",
  )
}

///|
test "a flag takes no value" {
  inspect(
    outcome("review", ["--request", "a", "--update-base=1"]),
    content="usage: Option '--update-base' does not take an argument",
  )
  inspect(
    outcome("review", ["--help=1"]),
    content="usage: Option '--help' does not take an argument",
  )
}

///|
test "review options conflict with a question to the reviewer" {
  inspect(
    outcome("review", ["--request", "a", "--ask", "q", "--model", "m"]),
    content="usage: --ask takes none of --update-base, --recover, --model and --thinking",
  )
  inspect(
    outcome("review", ["--request", "a", "--recover", "other"]),
    content="usage: --recover must be one of discard",
  )
  inspect(
    outcome("review", ["--ask", "q"]),
    content="usage: --request is required",
  )
  inspect(
    outcome("review", ["--request", "a", "--recover=discard", "--update-base"]),
    content="review request=a update_base=true discard=true ask=(none)",
  )
}

///|
test "resolve takes exactly one of sent and not-sent" {
  inspect(
    outcome("resolve", ["--request", "a"]),
    content="usage: exactly one of --sent and --not-sent is required",
  )
  inspect(
    outcome("resolve", ["--request", "a", "--sent", "--not-sent"]),
    content="usage: exactly one of --sent and --not-sent is required",
  )
  inspect(
    outcome("resolve", ["--request", "a", "--not-sent", "--thread-id", "t"]),
    content="resolve request=a sent=false thread=t",
  )
}

///|
test "watch keeps every pr and allows one mode" {
  inspect(
    outcome("watch", ["--dry-run", "--pr", "1", "--pr=2"]),
    content="watch dry_run=true prs=1,2 release=(none) status=false sender=false link=(none)",
  )
  inspect(
    outcome("watch", ["--pr", "1"]),
    content="usage: --pr is only for --dry-run",
  )
  inspect(
    outcome("watch", ["--status", "--sender"]),
    content="usage: use only one of --dry-run, --release, --status, --sender and --link",
  )
  inspect(
    outcome("watch", []),
    content="watch dry_run=false prs= release=(none) status=false sender=false link=(none)",
  )
}

///|
test "cloud takes exactly one of link and prompt file" {
  inspect(
    outcome("cloud", []),
    content="usage: exactly one of --link and --prompt-file is required",
  )
  inspect(
    outcome("cloud", ["--link", "s", "--prompt-file", "p"]),
    content="usage: exactly one of --link and --prompt-file is required",
  )
  inspect(
    outcome("cloud", ["--prompt-file", "p", "--project", "x"]),
    content="cloud link=(none) prompt_file=p project=x",
  )
}

///|
test "required options are named, and the other commands take none" {
  inspect(outcome("launch", []), content="usage: --request is required")
  inspect(outcome("name", []), content="usage: --pr is required")
  inspect(outcome("name", ["--pr", "1"]), content="name pr=1")
  inspect(outcome("state", []), content="state request=(none)")
  inspect(outcome("environment", []), content="environment")
  inspect(
    command_names().join(","),
    content="launch,review,state,resolve,name,watch,environment,check,cloud",
  )
}

///|
test "a name is split at the first equals sign by code unit" {
  inspect(
    outcome("check", ["--\u{1F600}=1"]),
    content="usage: Unknown option '--\u{1F600}'",
  )
  inspect(
    outcome("check", ["--\u{E9}=1"]),
    content="usage: Unknown option '--\u{E9}'",
  )
  inspect(
    outcome("name", ["--pr=\u{1F600}\u{E9}"]),
    content="name pr=\u{1F600}\u{E9}",
  )
}
