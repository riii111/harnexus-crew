///|
priv suberror Unexpected {
  Unexpected
}

///|
fn homeless_env(vars : Array[(String, String)]) -> () -> @environment.Env raise {
  () => @testkit.env_of(vars)
}

///|
async test "a usage error is reported without reading the environment" {
  let refusing : () -> @environment.Env raise = () => fail("env was read")

  assert_eq(run(["launch"][:], refusing).code, 2)
}

///|
async test "help is printed without reading the environment" {
  let refusing : () -> @environment.Env raise = () => fail("env was read")
  for argv in [["check", "-h"], ["-h"]] {
    assert_eq(run(argv[:], refusing).code, 0, msg=argv.join(" "))
  }
}

///|
async test "an error nothing expected ends with code 1 and a crash report naming where to report it" {
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
  let env = homeless_env([("HARNEXUS_EXECUTION_ENV", "local")])

  let result = run(["environment"][:], env)

  assert_eq(result.code, 0)
  assert_eq(
    result.stdout,
    "{\"environment\":\"local\",\"source\":\"explicit\",\"app\":\"codex\",\"note\":\"set by HARNEXUS_EXECUTION_ENV\"}\n",
  )
}

///|
async test "a command that needs the home fails when HOME is not set" {
  for argv in [["environment"], ["state"], ["adapter", "serve", "--id", "a"]] {
    let result = run(argv[:], homeless_env([]))
    assert_eq(result.code, 1, msg=argv.join(" "))
    assert_eq(
      result.stderr,
      "harnexus-crew: HOME is not set\n",
      msg=argv.join(" "),
    )
  }
}

///|
async test "adapter help is printed without a home" {
  assert_eq(run(["adapter", "-h"][:], homeless_env([])).code, 0)
}

///|
async test "an adapter usage error is reported without a home" {
  assert_eq(run(["adapter", "bogus"][:], homeless_env([])).code, 2)
}
