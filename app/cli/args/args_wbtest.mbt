///|
test "an option value follows after a space or an equals sign" {
  inspect(
    describe_parse("launch", ["--request", "a"]),
    content="launch request=a model=(none) thinking=(none)",
  )
  inspect(
    describe_parse("launch", ["--request=a=b", "--model", "-"]),
    content="launch request=a=b model=- thinking=(none)",
  )
}

///|
test "the last occurrence of a repeated option wins" {
  inspect(
    describe_parse("launch", ["--request", "a", "--request", "b", "--request="]),
    content="launch request= model=(none) thinking=(none)",
  )
}

///|
test "help wins over a missing option" {
  inspect(describe_parse("launch", ["-h"]), content="help")
  inspect(describe_parse("launch", ["--help"]), content="help")
}

///|
test "help does not win over a bad option" {
  inspect(describe_parse("launch", ["-h"]), content="help")
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
test "an unknown option is refused with its name" {
  let unknown = [
    ("--nope", "--nope"),
    ("--nope=1", "--nope"),
    ("-x", "-x"),
    ("-hx", "-hx"),
    ("-h=1", "-h=1"),
    ("--=x", "--=x"),
    ("---x", "---x"),
    ("--req", "--req"),
  ]

  for option in unknown {
    assert_eq(
      describe_parse("check", [option.0]),
      "usage: Unknown option '\{option.1}'",
      msg=option.0,
    )
  }
}

///|
test "a stray argument is refused" {
  for arg in ["pos", "-", ""] {
    assert_eq(
      describe_parse("check", [arg]),
      "usage: Unexpected argument '\{arg}'. This command does not take positional arguments",
      msg=arg,
    )
  }
}

///|
test "a lone double dash ends the options" {
  inspect(describe_parse("check", ["--"]), content="check")
  inspect(
    describe_parse("launch", ["--request", "a", "--"]),
    content="launch request=a model=(none) thinking=(none)",
  )
}

///|
test "an argument after a lone double dash is refused as a stray argument" {
  inspect(describe_parse("check", ["--"]), content="check")

  for arg in ["--", "--help"] {
    assert_eq(
      describe_parse("check", ["--", arg]),
      "usage: Unexpected argument '\{arg}'. This command does not take positional arguments",
      msg=arg,
    )
  }
}

///|
test "a value that looks like an option is ambiguous" {
  let ambiguous = "usage: Option '--request' argument is ambiguous.\nDid you forget to specify the option argument for '--request'?\nTo specify an option argument starting with a dash use '--request=-XYZ'."

  for value in ["--model", "-1", "--"] {
    assert_eq(
      describe_parse("launch", ["--request", value]),
      ambiguous,
      msg=value,
    )
  }
}

///|
test "a value that starts with a dash is taken after an equals sign" {
  inspect(
    describe_parse("launch", ["--request=--x"]),
    content="launch request=--x model=(none) thinking=(none)",
  )
}

///|
test "a missing option value is named" {
  inspect(
    describe_parse("launch", ["--request"]),
    content="usage: Option '--request <value>' argument missing",
  )
}

///|
test "a flag takes no value" {
  let flags = [
    (["--request", "a", "--update-base=1"], "--update-base"),
    (["--help=1"], "--help"),
  ]

  for flag in flags {
    assert_eq(
      describe_parse("review", flag.0),
      "usage: Option '\{flag.1}' does not take an argument",
      msg=flag.1,
    )
  }
}

///|
test "a question to the reviewer conflicts with the other review options" {
  inspect(
    describe_parse("review", ["--request", "a", "--ask", "q", "--model", "m"]),
    content="usage: --ask takes none of --update-base, --recover, --model and --thinking",
  )
}

///|
test "review recovers only by discarding" {
  inspect(
    describe_parse("review", [
      "--request", "a", "--recover=discard", "--update-base",
    ]),
    content="review request=a update_base=true discard=true ask=(none)",
  )
  inspect(
    describe_parse("review", ["--request", "a", "--recover", "other"]),
    content="usage: --recover must be one of discard",
  )
}

///|
test "a review needs --request even when it asks a question" {
  inspect(
    describe_parse("review", ["--ask", "q"]),
    content="usage: --request is required",
  )
}

///|
test "resolve refuses neither or both of sent and not-sent" {
  let both = ["--request", "a", "--sent", "--not-sent"]
  let neither = ["--request", "a"]
  for argv in [neither, both] {
    assert_eq(
      describe_parse("resolve", argv),
      "usage: exactly one of --sent and --not-sent is required",
      msg=argv.join(" "),
    )
  }
}

///|
test "resolve with not-sent keeps the thread id" {
  inspect(
    describe_parse("resolve", [
      "--request", "a", "--not-sent", "--thread-id", "t",
    ]),
    content="resolve request=a sent=false thread=t",
  )
}

///|
test "watch keeps every pr" {
  inspect(
    describe_parse("watch", ["--dry-run", "--pr", "1", "--pr=2"]),
    content="watch dry_run=true prs=1,2 release=(none) status=false sender=false link=(none)",
  )
}

///|
test "watch takes --pr only with --dry-run" {
  inspect(
    describe_parse("watch", ["--pr", "1"]),
    content="usage: --pr is only for --dry-run",
  )
}

///|
test "watch allows only one mode" {
  inspect(
    describe_parse("watch", ["--status", "--sender"]),
    content="usage: use only one of --dry-run, --release, --status, --sender and --link",
  )
}

///|
test "watch without options takes no mode" {
  inspect(
    describe_parse("watch", []),
    content="watch dry_run=false prs= release=(none) status=false sender=false link=(none)",
  )
}

///|
test "cloud refuses neither or both of link and prompt file" {
  let neither = []
  let both = ["--link", "s", "--prompt-file", "p"]
  for argv in [neither, both] {
    assert_eq(
      describe_parse("cloud", argv),
      "usage: exactly one of --link and --prompt-file is required",
      msg=argv.join(" "),
    )
  }
}

///|
test "cloud takes a prompt file with a project" {
  inspect(
    describe_parse("cloud", ["--prompt-file", "p", "--project", "x"]),
    content="cloud link=(none) prompt_file=p project=x",
  )
}

///|
test "a missing required option is named" {
  inspect(describe_parse("launch", []), content="usage: --request is required")
  inspect(describe_parse("name", []), content="usage: --pr is required")
}

///|
test "name takes its required option" {
  inspect(describe_parse("name", ["--pr", "1"]), content="name pr=1")
}

///|
test "state and environment take no option" {
  inspect(describe_parse("state", []), content="state request=(none)")
  inspect(describe_parse("environment", []), content="environment")
}

///|
test "the command names are listed in order" {
  inspect(
    command_names().join(","),
    content="launch,review,state,resolve,name,watch,environment,check,cloud",
  )
}

///|
test "an unknown option name is cut at the first equals sign by code unit" {
  inspect(
    describe_parse("check", ["--\u{1F600}=1"]),
    content="usage: Unknown option '--\u{1F600}'",
  )
  inspect(
    describe_parse("check", ["--\u{E9}=1"]),
    content="usage: Unknown option '--\u{E9}'",
  )
}

///|
test "a value after the first equals sign keeps its non-ASCII characters" {
  inspect(
    describe_parse("name", ["--pr=\u{1F600}\u{E9}"]),
    content="name pr=\u{1F600}\u{E9}",
  )
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
fn show_option(value : String?) -> String {
  value.unwrap_or("(none)")
}
