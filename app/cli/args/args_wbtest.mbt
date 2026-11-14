///|
fn show_option(value : String?) -> String {
  value.unwrap_or("(none)")
}

///|
fn describe_parse(command : String, rest : Array[String]) -> String {
  try {
    match parse_command(command, rest[:]) {
      Help => "help"
      Run(Launch(a)) =>
        "launch request=\{a.request} model=\{show_option(a.model)} thinking=\{show_option(a.thinking)}"
      Run(Review(a)) =>
        "review request=\{a.request} update_base=\{a.update_base} discard=\{a.discard_pending} ask=\{show_option(a.ask)}"
      Run(State(a)) => "state request=\{show_option(a.request)}"
      Run(Resolve(a)) =>
        "resolve request=\{a.request} sent=\{a.sent} thread=\{show_option(a.thread_id)}"
      Run(Name(a)) => "name pr=\{a.pr}"
      Run(Watch(a)) =>
        "watch dry_run=\{a.dry_run} prs=\{a.prs.join(",")} release=\{show_option(a.release)} status=\{a.status} sender=\{a.sender} link=\{show_option(a.link)}"
      Run(Cloud(a)) =>
        "cloud link=\{show_option(a.link)} prompt_file=\{show_option(a.prompt_file)} project=\{show_option(a.project)}"
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
    describe_parse("launch", ["--request", "a"]),
    content="launch request=a model=(none) thinking=(none)",
  )
  inspect(
    describe_parse("launch", ["--request=a=b", "--model", "-"]),
    content="launch request=a=b model=- thinking=(none)",
  )
  inspect(
    describe_parse("launch", ["--request", "a", "--request", "b", "--request="]),
    content="launch request= model=(none) thinking=(none)",
  )
}

///|
test "help wins over a missing option but not over a bad one" {
  inspect(describe_parse("launch", ["-h"]), content="help")
  inspect(describe_parse("launch", ["--help"]), content="help")
  inspect(
    describe_parse("launch", ["-hh"]),
    content="usage: Unknown option '-hh'",
  )
  inspect(
    describe_parse("launch", ["-h", "--nope"]),
    content="usage: Unknown option '--nope'",
  )
}

///|
test "an unknown option or a stray argument is refused" {
  inspect(
    describe_parse("check", ["--nope"]),
    content="usage: Unknown option '--nope'",
  )
  inspect(
    describe_parse("check", ["--nope=1"]),
    content="usage: Unknown option '--nope'",
  )
  inspect(describe_parse("check", ["-x"]), content="usage: Unknown option '-x'")
  inspect(
    describe_parse("check", ["-hx"]),
    content="usage: Unknown option '-hx'",
  )
  inspect(
    describe_parse("check", ["-h=1"]),
    content="usage: Unknown option '-h=1'",
  )
  inspect(
    describe_parse("check", ["--=x"]),
    content="usage: Unknown option '--=x'",
  )
  inspect(
    describe_parse("check", ["---x"]),
    content="usage: Unknown option '---x'",
  )
  inspect(
    describe_parse("check", ["--req"]),
    content="usage: Unknown option '--req'",
  )
  inspect(
    describe_parse("check", ["pos"]),
    content="usage: Unexpected argument 'pos'. This command does not take positional arguments",
  )
  inspect(
    describe_parse("check", ["-"]),
    content="usage: Unexpected argument '-'. This command does not take positional arguments",
  )
  inspect(
    describe_parse("check", [""]),
    content="usage: Unexpected argument ''. This command does not take positional arguments",
  )
}

///|
test "a lone double dash ends the options and nothing may follow it" {
  inspect(describe_parse("check", ["--"]), content="check")
  inspect(
    describe_parse("check", ["--", "--"]),
    content="usage: Unexpected argument '--'. This command does not take positional arguments",
  )
  inspect(
    describe_parse("check", ["--", "--help"]),
    content="usage: Unexpected argument '--help'. This command does not take positional arguments",
  )
  inspect(
    describe_parse("launch", ["--request", "a", "--"]),
    content="launch request=a model=(none) thinking=(none)",
  )
}

///|
test "a value that looks like an option is ambiguous, and a missing one is named" {
  let ambiguous = "usage: Option '--request' argument is ambiguous.\nDid you forget to specify the option argument for '--request'?\nTo specify an option argument starting with a dash use '--request=-XYZ'."
  inspect(describe_parse("launch", ["--request", "--model"]), content=ambiguous)
  inspect(describe_parse("launch", ["--request", "-1"]), content=ambiguous)
  inspect(describe_parse("launch", ["--request", "--"]), content=ambiguous)
  inspect(
    describe_parse("launch", ["--request"]),
    content="usage: Option '--request <value>' argument missing",
  )
  inspect(
    describe_parse("launch", ["--request=--x"]),
    content="launch request=--x model=(none) thinking=(none)",
  )
}

///|
test "a flag takes no value" {
  inspect(
    describe_parse("review", ["--request", "a", "--update-base=1"]),
    content="usage: Option '--update-base' does not take an argument",
  )
  inspect(
    describe_parse("review", ["--help=1"]),
    content="usage: Option '--help' does not take an argument",
  )
}

///|
test "review options conflict with a question to the reviewer" {
  inspect(
    describe_parse("review", ["--request", "a", "--ask", "q", "--model", "m"]),
    content="usage: --ask takes none of --update-base, --recover, --model and --thinking",
  )
  inspect(
    describe_parse("review", ["--request", "a", "--recover", "other"]),
    content="usage: --recover must be one of discard",
  )
  inspect(
    describe_parse("review", ["--ask", "q"]),
    content="usage: --request is required",
  )
  inspect(
    describe_parse("review", [
      "--request", "a", "--recover=discard", "--update-base",
    ]),
    content="review request=a update_base=true discard=true ask=(none)",
  )
}

///|
test "resolve takes exactly one of sent and not-sent" {
  inspect(
    describe_parse("resolve", ["--request", "a"]),
    content="usage: exactly one of --sent and --not-sent is required",
  )
  inspect(
    describe_parse("resolve", ["--request", "a", "--sent", "--not-sent"]),
    content="usage: exactly one of --sent and --not-sent is required",
  )
  inspect(
    describe_parse("resolve", [
      "--request", "a", "--not-sent", "--thread-id", "t",
    ]),
    content="resolve request=a sent=false thread=t",
  )
}

///|
test "watch keeps every pr and allows one mode" {
  inspect(
    describe_parse("watch", ["--dry-run", "--pr", "1", "--pr=2"]),
    content="watch dry_run=true prs=1,2 release=(none) status=false sender=false link=(none)",
  )
  inspect(
    describe_parse("watch", ["--pr", "1"]),
    content="usage: --pr is only for --dry-run",
  )
  inspect(
    describe_parse("watch", ["--status", "--sender"]),
    content="usage: use only one of --dry-run, --release, --status, --sender and --link",
  )
  inspect(
    describe_parse("watch", []),
    content="watch dry_run=false prs= release=(none) status=false sender=false link=(none)",
  )
}

///|
test "cloud takes exactly one of link and prompt file" {
  inspect(
    describe_parse("cloud", []),
    content="usage: exactly one of --link and --prompt-file is required",
  )
  inspect(
    describe_parse("cloud", ["--link", "s", "--prompt-file", "p"]),
    content="usage: exactly one of --link and --prompt-file is required",
  )
  inspect(
    describe_parse("cloud", ["--prompt-file", "p", "--project", "x"]),
    content="cloud link=(none) prompt_file=p project=x",
  )
}

///|
test "required options are named, and the other commands take none" {
  inspect(describe_parse("launch", []), content="usage: --request is required")
  inspect(describe_parse("name", []), content="usage: --pr is required")
  inspect(describe_parse("name", ["--pr", "1"]), content="name pr=1")
  inspect(describe_parse("state", []), content="state request=(none)")
  inspect(describe_parse("environment", []), content="environment")
  inspect(
    command_names().join(","),
    content="launch,review,state,resolve,name,watch,environment,check,cloud",
  )
}

///|
test "a name is split at the first equals sign by code unit" {
  inspect(
    describe_parse("check", ["--\u{1F600}=1"]),
    content="usage: Unknown option '--\u{1F600}'",
  )
  inspect(
    describe_parse("check", ["--\u{E9}=1"]),
    content="usage: Unknown option '--\u{E9}'",
  )
  inspect(
    describe_parse("name", ["--pr=\u{1F600}\u{E9}"]),
    content="name pr=\u{1F600}\u{E9}",
  )
}
