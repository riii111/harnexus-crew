///|
priv suberror Unexpected {
  Unexpected
}

///|
fn homeless_env(vars : Array[(String, String)]) -> () -> @environment.Env raise {
  let map : Map[String, String] = Map([])
  for pair in vars {
    map[pair.0] = pair.1
  }
  () => @environment.Env::new(map)
}

///|
async test "usage is checked before anything is read from the environment" {
  let refusing : () -> @environment.Env raise = () => fail("env was read")
  assert_eq(run(["launch"][:], refusing).code, 2)
  assert_eq(run(["check", "-h"][:], refusing).code, 0)
  assert_eq(run(["-h"][:], refusing).code, 0)
}

///|
async test "an error nothing expected is reported as a crash with where to report it" {
  let crashing : () -> @environment.Env raise = () => raise Unexpected
  let result = run(["environment"][:], crashing)
  assert_eq(result.code, 1)
  assert_eq(result.stdout, "")
  inspect(
    result.stderr,
    content=(
      #|harnexus-crew: unexpected failure: riii111/harnexus-crew/app/cli.Unexpected.Unexpected
      #|To report a bug, open an issue at https://github.com/riii111/taskctl/issues with the command you ran and its output.
      #|
    ),
  )
}

///|
async test "environment needs no home when the declaration settles it" {
  let result = run(
    ["environment"][:],
    homeless_env([("HARNEXUS_EXECUTION_ENV", "local")]),
  )
  assert_eq(result.code, 0)
  assert_true(result.stdout.contains("\"source\":\"explicit\""))
}

///|
async test "a command that needs the home fails when HOME is not set" {
  for argv in [["environment"], ["state"], ["adapter", "serve", "--id", "a"]] {
    let result = run(argv[:], homeless_env([]))
    assert_eq(result.code, 1)
    assert_eq(result.stderr, "harnexus-crew: HOME is not set\n")
  }
}

///|
async test "adapter usage and help need no home" {
  assert_eq(run(["adapter", "-h"][:], homeless_env([])).code, 0)
  assert_eq(run(["adapter", "bogus"][:], homeless_env([])).code, 2)
}
