///|
let gate : @async.Mutex = @async.Mutex()

///|
/// The test driver runs up to ten tests at once on one thread.
/// Tests that count descriptors or time a deadline run one at a time so another test's children and sleeps do not show up in them.
async fn serial(body : async () -> Unit) -> Unit {
  gate.acquire()
  defer gate.release()
  body()
}

///|
fn plain_env() -> Map[String, String] {
  { "PATH": "/usr/bin:/bin" }
}

///|
/// The mock commands that live with the test data.
fn mock(name : String) -> String {
  "\{@env.current_dir().unwrap()}/test/native/mocks/\{name}"
}

///|
fn scratch(name : String) -> String {
  let base = @env.get_env_var("TMPDIR").unwrap_or("/tmp")
  "\{base}/hxc-\{@testkit.pid()}-\{name}"
}

///|
async fn[T] timed(work : async () -> T) -> (T, Int32) {
  let started = @async.now()
  let value = work()
  (value, (@async.now() - started).to_int())
}

///|
fn assert_between(value : Int32, low : Int32, high : Int32) -> Unit raise {
  if value < low || value > high {
    fail("\{value} is outside \{low}..\{high}")
  }
}

///|
/// How a run ended in one line, with the output only when asked for.
async fn outcome(
  file : String,
  args : Array[String],
  input~ : String = "",
  timeout_ms~ : Int32 = 1000,
  kill_grace_ms~ : Int32 = 500,
  cwd~ : String = "/",
  env~ : Map[String, String] = plain_env(),
  output~ : Bool = false,
) -> String {
  try {
    let run = run_process(
      file,
      args,
      input,
      cwd~,
      env~,
      timeout_ms~,
      kill_grace_ms~,
    )
    let head = "started ended=\{run.ended.name()} status=\{run.status}"
    if output {
      "\{head} stdout=\{Json::string(run.stdout).stringify()} stderr=\{Json::string(run.stderr).stringify()}"
    } else {
      head
    }
  } catch {
    @boundary.ProcessRunFailed(started~, message~) =>
      "failed started=\{started}: \{message}"
  }
}

///|
async fn shell(script : String) -> String {
  let ran = run_command("/bin/sh", ["-c", script], plain_env())
  ran.stdout
}

///|
/// Waits for a process to be gone: signalled children are collected by init a moment after they die.
async fn is_gone(pid : Int32) -> Bool {
  for _ in 0..<200 {
    if !@testkit.alive(pid) {
      return true
    }
    @async.sleep(10)
  }
  false
}

///|
async fn pid_in(file : String) -> Int32 {
  @string.parse_int(shell("cat \{file}").trim().to_owned()) catch {
    _ => -1
  }
}

///|
async test "E1 a missing command never started" {
  serial(() => {
    let before = @testkit.open_fds()
    assert_eq(
      outcome("/nonexistent/cmd", []),
      "failed started=false: cannot run /nonexistent/cmd (ENOENT)",
    )
    assert_eq(
      outcome("nonexistent-cmd", []),
      "failed started=false: cannot run nonexistent-cmd (ENOENT)",
    )
    assert_eq(@testkit.open_fds(), before)
  })
}

///|
async test "E2 a file without execute permission never started" {
  serial(() => {
    let result = outcome(mock("noexec.sh"), [])
    assert_true(result.has_prefix("failed started=false: "))
    assert_true(result.contains("(EACCES)"))
  })
}

///|
async test "E3 a script whose interpreter is missing never started" {
  serial(() => {
    let result = outcome(mock("badshebang.sh"), [])
    assert_true(result.has_prefix("failed started=false: "))
    assert_true(result.contains("ENOENT"))
  })
}

///|
async test "a missing working directory never started" {
  serial(() => {
    let result = outcome("/bin/sh", ["-c", "exit 0"], cwd="/nonexistent/dir")
    assert_true(result.has_prefix("failed started=false: "))
    assert_true(result.contains("ENOENT"))
  })
}

///|
async test "E4 a program that exits 127 is a result, not a start failure" {
  serial(() => {
    assert_eq(
      outcome("/bin/sh", ["-c", "exit 127"]),
      "started ended=exit status=127",
    )
  })
}

///|
fn spawn_missing_with_stdio_closed() -> (Int32, Int32, Int32) raise {
  let saved = @testkit.close_stdio()
  let before = @testkit.open_fds()
  // The synchronous `spawn` is called directly because a print or a wait while descriptors 0 to 2 are closed would hit the test runner's own output.
  let errno = try {
    let child = spawn(
      "/nonexistent/cmd",
      [],
      plain_env(),
      "/",
      piped=true,
      new_session=true,
    )
    child.stop_and_reap()
    child.release_pipes()
    0
  } catch {
    SpawnFailed(errno~) => errno
    InvalidArgument => -1
  }
  let after = @testkit.open_fds()
  @testkit.restore_stdio(saved)
  (errno, before, after)
}

///|
async test "a missing command never started even when stdin, stdout and stderr are closed" {
  serial(() => {
    let (errno, before, after) = spawn_missing_with_stdio_closed()
    assert_eq(errno, 2)
    assert_eq(after, before)
  })
}

///|
async test "P1 stdin reaches the command and a character split across writes is read whole" {
  serial(() => {
    assert_eq(
      outcome(
        "/bin/sh",
        [mock("child.sh"), "echo"],
        input="hello-stdin",
        timeout_ms=3000,
        kill_grace_ms=300,
        output=true,
      ),
      "started ended=exit status=3 stdout=\"hello-stdinあ\\n\" stderr=\"err-line\\n\"",
    )
  })
}

///|
async test "a character split across chunks is whole on stdout and on stderr" {
  serial(() => {
    let script = "printf '{\"text\":\"\\343'; sleep 0.2; printf '\\201\\202\"}'; printf '\\343' >&2; sleep 0.2; printf '\\201\\202' >&2"
    assert_eq(
      outcome(
        "/bin/sh",
        ["-c", script],
        timeout_ms=10000,
        kill_grace_ms=1000,
        output=true,
      ),
      "started ended=exit status=0 stdout=\"{\\\"text\\\":\\\"あ\\\"}\" stderr=\"あ\"",
    )
  })
}

///|
async test "output that is not UTF-8 becomes U+FFFD like Node decodes it" {
  serial(() => {
    assert_eq(
      outcome("/usr/bin/printf", ["\\377\\343A\\355\\240\\200"], output=true),
      "started ended=exit status=0 stdout=\"\u{fffd}\u{fffd}A\u{fffd}\u{fffd}\u{fffd}\" stderr=\"\"",
    )
  })
}

///|
async test "P3 a grandchild that ignores SIGTERM is killed after the grace, with the leader's status kept" {
  serial(() => {
    let dir = scratch("p3")
    ignore(shell("mkdir -p \{dir}"))
    defer @async.protect_from_cancel(() => ignore(shell("rm -rf \{dir}")))
    let pidfile = "\{dir}/pid"
    let (result, elapsed) = timed(() => {
      outcome("/bin/sh", [mock("child.sh"), "term-ok", pidfile])
    })
    assert_eq(result, "started ended=timeout status=143")
    assert_between(elapsed, 1200, 2300)
    assert_true(is_gone(pid_in(pidfile)))
    assert_true(is_gone(pid_in("\{pidfile}.gc")))
  })
}

///|
async test "P4 a leader that ignores SIGTERM is killed after the grace" {
  serial(() => {
    let dir = scratch("p4")
    ignore(shell("mkdir -p \{dir}"))
    defer @async.protect_from_cancel(() => ignore(shell("rm -rf \{dir}")))
    let pidfile = "\{dir}/pid"
    let (result, elapsed) = timed(() => {
      outcome("/bin/sh", [mock("child.sh"), "ignore-term", pidfile])
    })
    assert_eq(result, "started ended=timeout status=1")
    assert_between(elapsed, 1200, 2300)
    assert_true(is_gone(pid_in(pidfile)))
    assert_true(is_gone(pid_in("\{pidfile}.gc")))
  })
}

///|
async test "P5 output past 16 MiB stops the command and keeps at most 16 MiB" {
  serial(() => {
    let dir = scratch("p5")
    ignore(shell("mkdir -p \{dir}"))
    defer @async.protect_from_cancel(() => ignore(shell("rm -rf \{dir}")))
    let pidfile = "\{dir}/pid"
    let run = run_process(
      "/bin/sh",
      ["-c", "echo $$ > \{pidfile}; exec yes"],
      "",
      cwd="/",
      env=plain_env(),
      timeout_ms=10000,
      kill_grace_ms=500,
    )
    assert_eq(run.ended.name(), "output-limit")
    assert_true(run.stdout.length() + run.stderr.length() <= 16777216)
    assert_true(run.stdout.length() > 8000000)
    assert_true(is_gone(pid_in(pidfile)))
  })
}

///|
async test "a command that exits without reading its input is not an error" {
  serial(() => {
    let input = String::make(2 * 1024 * 1024, 'x')
    assert_eq(
      outcome("/usr/bin/true", [], input~),
      "started ended=exit status=0",
    )
  })
}

///|
async test "the environment is exactly the one given, and the working directory is applied" {
  serial(() => {
    assert_eq(
      outcome(
        "/usr/bin/env",
        [],
        env={ "A": "1", "B": "two words" },
        output=true,
      ),
      "started ended=exit status=0 stdout=\"A=1\\nB=two words\\n\" stderr=\"\"",
    )
    assert_eq(
      outcome("/bin/pwd", [], cwd="/", output=true),
      "started ended=exit status=0 stdout=\"/\\n\" stderr=\"\"",
    )
  })
}

///|
async test "a bare command name is looked up in the PATH of the given environment" {
  serial(() => {
    assert_eq(
      outcome("sh", ["-c", "exit 4"], env={ "PATH": "/bin" }),
      "started ended=exit status=4",
    )
    let missing = outcome("sh", ["-c", "exit 4"], env={ "PATH": "/nonexistent" })
    assert_true(missing.has_prefix("failed started=false: "))
  })
}

///|
async test "a megabyte of output is read whole" {
  serial(() => {
    let run = run_process(
      "/bin/sh",
      ["-c", "head -c 1048576 /dev/zero | tr '\\0' a"],
      "",
      cwd="/",
      env=plain_env(),
      timeout_ms=10000,
      kill_grace_ms=500,
    )
    assert_eq(run.stdout.length(), 1048576)
  })
}

///|
async test "several commands started at once keep their own results" {
  serial(() => {
    let results : Array[String] = Array::make(12, "")
    @async.with_task_group(group => {
      for i in 0..<12 {
        group.spawn_bg(() => {
          results[i] = if i % 2 == 0 {
            outcome("/bin/echo", ["n\{i}"], output=true)
          } else {
            outcome("/nonexistent/cmd\{i}", [])
          }
        })
      }
    })
    for i in 0..<12 {
      if i % 2 == 0 {
        assert_eq(
          results[i],
          "started ended=exit status=0 stdout=\"n\{i}\\n\" stderr=\"\"",
        )
      } else {
        assert_eq(
          results[i],
          "failed started=false: cannot run /nonexistent/cmd\{i} (ENOENT)",
        )
      }
    }
  })
}

///|
async test "a command started while another's stdin is still open does not inherit it" {
  serial(() => {
    // `cat` sees EOF only when every copy of its stdin's write end is closed, so a sleeper that inherited the parent's end would hold it for as long as it lives.
    let cat_ended = Ref(-1)
    let sleeper_ms = Ref(-1)
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        let (result, ms) = timed(() => {
          outcome("/bin/cat", [], input="hello", output=true)
        })
        assert_eq(
          result, "started ended=exit status=0 stdout=\"hello\" stderr=\"\"",
        )
        cat_ended.val = ms
      })
      group.spawn_bg(() => {
        let (_, ms) = timed(() => {
          outcome("/bin/sleep", ["1.5"], timeout_ms=5000)
        })
        sleeper_ms.val = ms
      })
    })
    assert_true(cat_ended.val >= 0 && cat_ended.val < 700)
    assert_true(sleeper_ms.val >= 1400)
  })
}

///|
async test "a command sees only the descriptors it was given, whatever else is starting" {
  serial(() => {
    let alone = outcome("/bin/ls", ["/dev/fd"], output=true)
    let crowded = Ref("")
    @async.with_task_group(group => {
      group.spawn_bg(() => ignore(outcome("/bin/cat", [], input="x")))
      group.spawn_bg(() => ignore(outcome("/bin/sleep", ["0.5"])))
      group.spawn_bg(() => {
        crowded.val = outcome("/bin/ls", ["/dev/fd"], output=true)
      })
    })
    assert_eq(crowded.val, alone)
  })
}

///|
async test "cancelling a run stops the command and its group and closes every descriptor" {
  serial(() => {
    let dir = scratch("cancel")
    ignore(shell("mkdir -p \{dir}"))
    defer @async.protect_from_cancel(() => ignore(shell("rm -rf \{dir}")))
    let pidfile = "\{dir}/pid"
    // Start once so the runtime's own descriptors exist before they are counted.
    ignore(outcome("/usr/bin/true", []))
    let before = @testkit.open_fds()
    let finished = @async.with_timeout_opt(300, () => {
      outcome(
        "/bin/sh",
        [mock("child.sh"), "term-ok", pidfile],
        timeout_ms=30000,
      )
    })
    assert_true(finished is None)
    assert_true(is_gone(pid_in(pidfile)))
    assert_true(is_gone(pid_in("\{pidfile}.gc")))
    assert_eq(@testkit.open_fds(), before)
  })
}

///|
async test "every finished run leaves no descriptor behind" {
  serial(() => {
    ignore(outcome("/usr/bin/true", []))
    let before = @testkit.open_fds()
    ignore(outcome("/bin/sh", ["-c", "exit 2"]))
    ignore(outcome("/nonexistent/cmd", []))
    ignore(outcome("/bin/sleep", ["5"], timeout_ms=200, kill_grace_ms=200))
    assert_eq(@testkit.open_fds(), before)
  })
}

///|
async test "run_command returns the status and output of a failing command" {
  serial(() => {
    let ran = run_command("/bin/sh", ["-c", "echo no >&2; exit 3"], plain_env())
    assert_eq(ran.status, 3)
    assert_eq(ran.stdout, "")
    assert_eq(ran.stderr, "no\n")
  })
}

///|
async test "run_command stops a command that runs past the timeout" {
  serial(() => {
    try
      run_command("/bin/sleep", ["5"], plain_env(), timeout_ms=50) |> ignore
    catch {
      @boundary.CommandFailed(command~, message~, ..) => {
        assert_eq(command, "/bin/sleep")
        assert_eq(message, "/bin/sleep was stopped after 50 ms")
      }
    } noraise {
      _ => fail("expected a failure")
    }
  })
}

///|
async test "run_command reports a command that cannot start or dies from a signal" {
  serial(() => {
    try run_command("/nonexistent/cmd", [], plain_env()) |> ignore catch {
      @boundary.CommandFailed(message~, ..) =>
        assert_eq(message, "cannot run /nonexistent/cmd")
    } noraise {
      _ => fail("expected a failure")
    }
    try
      run_command("/bin/sh", ["-c", "kill -9 $$"], plain_env()) |> ignore
    catch {
      @boundary.CommandFailed(message~, ..) =>
        assert_eq(message, "cannot run /bin/sh")
    } noraise {
      _ => fail("expected a failure")
    }
  })
}

///|
async test "run_command ends a command that reads stdin to its end instead of waiting for the timeout" {
  serial(() => {
    let ran = run_command("/bin/cat", [], plain_env(), timeout_ms=5000)
    assert_eq(ran.status, 0)
    assert_eq(ran.stdout, "")
  })
}

///|
async test "run_command sends SIGTERM once and waits for a command that ignores it" {
  serial(() => {
    let (failed, elapsed) = timed(() => {
      try
        run_command(
          "/bin/sh",
          ["-c", "trap '' TERM; sleep 1; echo late"],
          plain_env(),
          timeout_ms=100,
        )
        |> ignore
      catch {
        @boundary.CommandFailed(message~, ..) => message
      } noraise {
        _ => "no failure"
      }
    })
    assert_eq(failed, "/bin/sh was stopped after 100 ms")
    assert_between(elapsed, 900, 2500)
  })
}

///|
async test "run_command fails on output past 16 MiB" {
  serial(() => {
    try
      run_command("/usr/bin/yes", [], plain_env(), timeout_ms=20000) |> ignore
    catch {
      @boundary.CommandFailed(message~, ..) =>
        assert_eq(message, "cannot run /usr/bin/yes")
    } noraise {
      _ => fail("expected a failure")
    }
  })
}

///|
async test "run_inherited returns the exit status, and 128 plus the signal for a killed command" {
  serial(() => {
    assert_eq(run_inherited("/bin/sh", ["-c", "exit 7"], plain_env()), 7)
    assert_eq(run_inherited("/bin/sh", ["-c", "kill -9 $$"], plain_env()), 137)
    try run_inherited("/nonexistent/cmd", [], plain_env()) |> ignore catch {
      @boundary.CommandFailed(message~, ..) =>
        assert_eq(message, "cannot run /nonexistent/cmd")
    } noraise {
      _ => fail("expected a failure")
    }
  })
}

///|
async test "a command that cannot be stopped makes the run fail as started" {
  serial(() => {
    // The grandchild leaves the process group, so only the deadline can end the run, and it keeps the output pipes open.
    let script = "perl -MPOSIX -e 'POSIX::setsid(); exec q(sleep), q(3)' & exit 0"
    let before = @testkit.open_fds()
    let (result, elapsed) = timed(() => {
      outcome("/bin/sh", ["-c", script], timeout_ms=300, kill_grace_ms=200)
    })
    assert_true(
      result.has_prefix("failed started=true: /bin/sh did not finish: pid "),
    )
    assert_true(result.has_suffix(" did not exit after SIGKILL"))
    assert_between(elapsed, 600, 1500)
    assert_eq(@testkit.open_fds(), before)
  })
}

///|
async test "B1 cancelling a run whose leader already exited still ends the group and frees the descriptors" {
  serial(() => {
    let dir = scratch("b1")
    ignore(shell("mkdir -p \{dir}"))
    defer @async.protect_from_cancel(() => ignore(shell("rm -rf \{dir}")))
    let pidfile = "\{dir}/pid"
    ignore(outcome("/usr/bin/true", []))
    let before = @testkit.open_fds()
    let finished = @async.with_timeout_opt(300, () => {
      outcome(
        "/bin/sh",
        ["-c", "sleep 30 & echo $! > \{pidfile}; exit 0"],
        timeout_ms=30000,
      )
    })
    assert_true(finished is None)
    assert_true(is_gone(pid_in(pidfile)))
    assert_eq(@testkit.open_fds(), before)
  })
}

///|
async test "B2 run_command limits each stream on its own" {
  serial(() => {
    let both = run_command(
      "/bin/sh",
      ["-c", "head -c 10000000 /dev/zero; head -c 10000000 /dev/zero >&2"],
      plain_env(),
      timeout_ms=20000,
    )
    assert_eq(both.status, 0)
    assert_eq(both.stdout.length(), 10000000)
    assert_eq(both.stderr.length(), 10000000)
    try
      run_command(
        "/bin/sh",
        ["-c", "head -c 17000000 /dev/zero >&2"],
        plain_env(),
        timeout_ms=20000,
      )
      |> ignore
    catch {
      @boundary.CommandFailed(message~, ..) =>
        assert_eq(message, "cannot run /bin/sh")
    } noraise {
      _ => fail("expected a failure")
    }
  })
}

///|
async test "B3 a relative PATH entry is looked up under the working directory" {
  serial(() => {
    let dir = scratch("b3")
    ignore(
      shell(
        "mkdir -p \{dir}/bin && printf '#!/bin/sh\\necho found\\n' > \{dir}/bin/hxc-cmd && chmod +x \{dir}/bin/hxc-cmd",
      ),
    )
    defer @async.protect_from_cancel(() => ignore(shell("rm -rf \{dir}")))
    let found = "started ended=exit status=0 stdout=\"found\\n\" stderr=\"\""
    assert_eq(
      outcome("hxc-cmd", [], cwd=dir, env={ "PATH": "./bin" }, output=true),
      found,
    )
    assert_eq(
      outcome(
        "hxc-cmd",
        [],
        cwd="\{dir}/bin",
        env={ "PATH": "/nonexistent:" },
        output=true,
      ),
      found,
    )
    // An entry that exists only under the parent's directory is not a candidate.
    let missing = outcome("hxc-cmd", [], cwd="/", env={ "PATH": "./bin" })
    assert_true(missing.has_prefix("failed started=false: "))
  })
}

///|
async test "run_command keeps the error code Node attaches, only where Node has one" {
  serial(() => {
    let code_of = (file : String, args : Array[String], timeout_ms : Int32) => {
      try run_command(file, args, plain_env(), timeout_ms~) |> ignore catch {
        @boundary.CommandFailed(code~, ..) => code.unwrap_or("none")
      } noraise {
        _ => "no failure"
      }
    }
    assert_eq(code_of("/nonexistent/cmd", [], 1000), "ENOENT")
    assert_eq(code_of("git-not-here", [], 1000), "ENOENT")
    assert_eq(code_of("/bin/sleep", ["5"], 50), "none")
    assert_eq(code_of("/bin/sh", ["-c", "kill -9 $$"], 1000), "none")
    assert_eq(
      code_of("/bin/sh", ["-c", "head -c 17000000 /dev/zero"], 20000),
      "ERR_CHILD_PROCESS_STDIO_MAXBUFFER",
    )
  })
}
