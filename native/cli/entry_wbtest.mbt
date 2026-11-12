///|
fn env_of(vars : Array[(String, String)]) -> () -> @environment.Env raise {
  let map : Map[String, String] = Map([])
  for pair in vars {
    map[pair.0] = pair.1
  }
  () => @environment.Env::new(map, login_home="/home/login")
}

///|
async fn run_with(
  argv : Array[String],
  vars : Array[(String, String)],
) -> @run.CommandRun {
  run(argv[:], env_of(vars))
}

///|
async test "help lists every command and ends with the bug report hint" {
  let run = run_with(["--help"], [])
  assert_eq(run.code, 0)
  assert_eq(run.stderr, "")
  inspect(
    run.stdout,
    content=(
      #|usage:
      #|  harnexus-crew launch --request REQUEST [--model MODEL] [--thinking THINKING]
      #|  harnexus-crew review --request REQUEST [--model MODEL] [--thinking THINKING] [--update-base] [--recover discard] [--ask FILE]
      #|  harnexus-crew state [--request REQUEST]
      #|  harnexus-crew resolve --request REQUEST (--sent | --not-sent) [--thread-id THREAD_ID]
      #|  harnexus-crew name --pr PR
      #|  harnexus-crew watch [--dry-run [--pr PR]... | --release PR | --status | --sender | --link PR]
      #|  harnexus-crew environment
      #|  harnexus-crew check
      #|  harnexus-crew cloud (--link SESSION_OR_URL | --prompt-file FILE) [--project PROJECT_ID] [--title TITLE] [--model MODEL] [--thinking THINKING]
      #|To report a bug, open an issue at https://github.com/riii111/taskctl/issues with the command you ran and its output.
      #|
    ),
  )
  assert_eq(run_with(["-h"], []).stdout, run.stdout)
}

///|
async test "a missing or unknown subcommand is a usage error with the full usage" {
  let none = run_with([], [])
  assert_eq(none.code, 2)
  assert_eq(none.stdout, "")
  assert_true(none.stderr.has_prefix("usage:\n  harnexus-crew launch "))
  assert_true(
    none.stderr.has_suffix(
      "harnexus-crew: expected a subcommand: launch, review, state, resolve, name, watch, environment, check, cloud\n",
    ),
  )
  assert_eq(run_with(["bogus"], []).stderr, none.stderr)
}

///|
async test "a command's help and usage errors show only its own usage" {
  let help = run_with(["review", "--help"], [])
  assert_eq(help.code, 0)
  assert_true(help.stdout.has_prefix("usage:\n  harnexus-crew review "))
  assert_eq(help.stdout.split("\n").count(), 4)
  let bad = run_with(["launch"], [])
  assert_eq(bad.code, 2)
  inspect(
    bad.stderr,
    content=(
      #|usage:
      #|  harnexus-crew launch --request REQUEST [--model MODEL] [--thinking THINKING]
      #|harnexus-crew: --request is required
      #|
    ),
  )
}

///|
async test "usage is checked before anything is read from the environment" {
  let refusing : () -> @environment.Env raise = () => fail("env was read")
  assert_eq(run(["launch"][:], refusing).code, 2)
  assert_eq(run(["check", "-h"][:], refusing).code, 0)
}

///|
async test "commands no task has moved fail and never fall back" {
  let cases = [
    (["launch", "--request", "r"], "launch"),
    (["review", "--request", "r"], "review"),
    (["state", "--request", "r"], "state --request"),
    (["resolve", "--request", "r", "--sent"], "resolve"),
    (["name", "--pr", "1"], "name"),
    (["watch"], "watch"),
    (["cloud", "--link", "l"], "cloud"),
    (["adapter"], "adapter"),
    (["adapter", "serve"], "adapter"),
  ]
  for pair in cases {
    let run = run_with(pair.0, [])
    assert_eq(run.code, 1)
    assert_eq(run.stdout, "")
    assert_eq(
      run.stderr,
      "harnexus-crew: \{pair.1} is not available in this native build yet\n",
    )
  }
}

///|
async test "an error nothing expected is reported as a crash with where to report it" {
  let crashing : () -> @environment.Env raise = () => raise HomeNotFound
  let run = run(["environment"][:], crashing)
  assert_eq(run.code, 1)
  assert_eq(run.stdout, "")
  inspect(
    run.stderr,
    content=(
      #|harnexus-crew: unexpected failure: riii111/harnexus-crew/cli.HomeNotFound.HomeNotFound
      #|To report a bug, open an issue at https://github.com/riii111/taskctl/issues with the command you ran and its output.
      #|
    ),
  )
}

///|
async test "environment prints the declared environment as one JSON line" {
  let run = run_with(["environment"], [
    ("HARNEXUS_EXECUTION_ENV", "cloud"),
    ("CLAUDE_CODE_REMOTE", "true"),
  ])
  assert_eq(run.code, 0)
  assert_eq(
    run.stdout,
    "{\"environment\":\"cloud\",\"source\":\"explicit\",\"host\":\"claude\",\"note\":\"set by HARNEXUS_EXECUTION_ENV\"}\n",
  )
}

///|
async test "environment refuses an invalid declaration" {
  let run = run_with(["environment"], [("HARNEXUS_EXECUTION_ENV", "remote")])
  assert_eq(run.code, 1)
  assert_eq(
    run.stderr,
    "harnexus-crew: HARNEXUS_EXECUTION_ENV must be cloud or local, not \"remote\"\n",
  )
}

///|
async test "environment is local only when the call socket accepts a connection" {
  let path = "/tmp/hxc-cli-\{@testkit.pid()}.sock"
  let missing = run_with(["environment"], [("HARNEXUS_CALL_SOCKET", path)])
  assert_true(missing.stdout.contains("\"environment\":\"unknown\""))
  let listener = @testkit.listen(path)
  defer {
    @testkit.close_fd(listener)
    @testkit.remove_file(path)
  }
  let accepted = run_with(["environment"], [("HARNEXUS_CALL_SOCKET", path)])
  assert_eq(
    accepted.stdout,
    "{\"environment\":\"local\",\"source\":\"harnexus-socket\",\"app\":\"codex\",\"note\":\"the harnexus call socket accepted a connection\"}\n",
  )
}

///|
async test "state prints an empty object when no state was kept" {
  let run = run_with(["state"], [
    ("XDG_STATE_HOME", "/nonexistent-\{@env.now()}"),
  ])
  assert_eq(run.code, 0)
  assert_eq(run.stdout, "{}\n")
}
