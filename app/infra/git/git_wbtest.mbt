///|
async test "a git command runs without helpers or transports, in the checkout" {
  let seen = []
  let git = answering(ok(""), seen)

  ignore(git.run("/fx/wt", ["rev-parse", "--show-toplevel"]))

  inspect(
    seen[0].0.join(" "),
    content="git -c core.fsmonitor=false -c core.hooksPath=/dev/null -c protocol.allow=never -C /fx/wt rev-parse --show-toplevel",
  )
}

///|
async test "a git command never fetches lazily" {
  let seen = []
  let git = answering(ok(""), seen)

  ignore(git.run("/fx/wt", ["status"]))

  assert_eq(seen[0].1.get("GIT_NO_LAZY_FETCH"), Some("1"))
}

///|
async test "a git command keeps the caller's environment" {
  let seen = []
  let git = answering(ok(""), seen)

  ignore(git.run("/fx/wt", ["status"]))

  assert_eq(seen[0].1.get("HOME"), Some("/h"))
}

///|
async test "a git command returns its output without surrounding white space" {
  let git = answering(ok("  abc123\n"), [])

  inspect(git.run("/fx/wt", ["rev-parse", "HEAD"]), content="abc123")
}

///|
async test "a git that fails reports its message and that nothing is fetched" {
  let git = answering({ status: 128, stdout: "", stderr: "bad object\n", }, [])

  let shown = @apptestkit.failure_of(() => ignore(git.run("/fx/wt", ["log"])))

  inspect(
    shown,
    content="bad object; harnexus-crew never fetches, so fetch any missing commit in the worktree",
  )
}

///|
async test "a git that cannot run is shown with the error code" {
  let git = Git::new(
    {
      run: (_, _) => {
        raise @boundary.CommandFailed(
          command="git",
          message="cannot run git",
          code=Some("ENOENT"),
        )
      },
    },
    @apptestkit.env_of([]),
  )

  let shown = @apptestkit.failure_of(() => ignore(git.run("/w", ["status"])))

  inspect(shown, content="cannot run git (ENOENT)")
}

///|
async test "a git stopped without an error code is shown with its message alone" {
  let git = Git::new(
    {
      run: (_, _) => {
        raise @boundary.CommandFailed(
          command="git",
          message="git was stopped after 10000 ms",
          code=None,
        )
      },
    },
    @apptestkit.env_of([]),
  )

  let shown = @apptestkit.failure_of(() => ignore(git.run("/w", ["status"])))

  inspect(shown, content="git was stopped after 10000 ms")
}

///|
fn ok(stdout : String) -> @boundary.CommandOutput {
  { status: 0, stdout, stderr: "", }
}

///|
fn answering(
  output : @boundary.CommandOutput,
  seen : Array[(Array[String], Map[String, String])],
) -> Git {
  Git::new(
    {
      run: (argv, vars) => {
        seen.push((argv, vars))
        output
      },
    },
    @apptestkit.env_of([("HOME", "/h")]),
  )
}
