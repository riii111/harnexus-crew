///|
async test "E1 a missing command is reported as not started with ENOENT" {
  @testkit.serial(() => {
    assert_eq(
      describe_run("/nonexistent/cmd", []),
      "failed started=false: cannot run /nonexistent/cmd (ENOENT)",
    )
    assert_eq(
      describe_run("nonexistent-cmd", []),
      "failed started=false: cannot run nonexistent-cmd (ENOENT)",
    )
  })
}

///|
async test "a run of a missing command leaves no descriptor open" {
  @testkit.serial(() => {
    let before = @testkit.open_fds()

    let result = describe_run("/nonexistent/cmd", [])

    assert_eq(
      result, "failed started=false: cannot run /nonexistent/cmd (ENOENT)",
    )
    assert_eq(@testkit.open_fds(), before)
  })
}

///|
async test "E2 a file without execute permission is reported as not started with EACCES" {
  @testkit.serial(() => {
    let script = mock("noexec.sh")

    assert_eq(
      describe_run(script, []),
      "failed started=false: cannot run \{script} (EACCES)",
    )
  })
}

///|
async test "E3 a script whose interpreter is missing is reported as not started with ENOENT" {
  @testkit.serial(() => {
    let script = mock("badshebang.sh")

    assert_eq(
      describe_run(script, []),
      "failed started=false: cannot run \{script} (ENOENT)",
    )
  })
}

///|
async test "a missing working directory is reported as not started with ENOENT" {
  @testkit.serial(() => {
    let result = describe_run(
      "/bin/sh",
      ["-c", "exit 0"],
      cwd="/nonexistent/dir",
    )

    assert_eq(result, "failed started=false: cannot run /bin/sh (ENOENT)")
  })
}

///|
async test "E4 a program that exits 127 is a result, not a start failure" {
  @testkit.serial(() => {
    assert_eq(
      describe_run("/bin/sh", ["-c", "exit 127"]),
      "started ended=exit status=127",
    )
  })
}

///|
async test "a missing command fails with ENOENT even when stdin, stdout and stderr are closed" {
  @testkit.serial(() => {
    let (errno, _, _) = spawn_missing_with_stdio_closed()

    assert_eq(errno, 2)
  })
}

///|
async test "a missing command leaves no descriptor open even when stdin, stdout and stderr are closed" {
  @testkit.serial(() => {
    let (errno, before, after) = spawn_missing_with_stdio_closed()

    assert_eq(errno, 2)
    assert_eq(after, before)
  })
}

///|
async test "P1 a run feeds stdin to the command and returns its stdout, stderr and exit status" {
  @testkit.serial(() => {
    assert_eq(
      describe_run(
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
  @testkit.serial(() => {
    let script = "printf '{\"text\":\"\\343'; sleep 0.2; printf '\\201\\202\"}'; printf '\\343' >&2; sleep 0.2; printf '\\201\\202' >&2"
    assert_eq(
      describe_run(
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
  @testkit.serial(() => {
    assert_eq(
      describe_run(
        "/usr/bin/printf",
        ["\\377\\343A\\355\\240\\200"],
        output=true,
      ),
      "started ended=exit status=0 stdout=\"\u{fffd}\u{fffd}A\u{fffd}\u{fffd}\u{fffd}\" stderr=\"\"",
    )
  })
}

///|
async test "P3 a timeout keeps the leader's status when a grandchild ignores SIGTERM" {
  @testkit.serial(() => {
    let dir = @testkit.scratch("p3-status")
    defer @async.protect_from_cancel(() => @testkit.remove_tree(dir))
    let pidfile = "\{dir}/pid"

    let result = describe_run("/bin/sh", [mock("child.sh"), "term-ok", pidfile])

    assert_eq(result, "started ended=timeout status=143")
  })
}

///|
async test "P3 a grandchild that ignores SIGTERM is killed after the grace" {
  @testkit.serial(() => {
    let dir = @testkit.scratch("p3")
    defer @async.protect_from_cancel(() => @testkit.remove_tree(dir))
    let pidfile = "\{dir}/pid"

    let (result, elapsed) = @testkit.timed(() => {
      describe_run("/bin/sh", [mock("child.sh"), "term-ok", pidfile])
    })

    assert_eq(result, "started ended=timeout status=143")
    @testkit.assert_between(elapsed, 1200, 2300)
    assert_gone(pidfile)
    assert_gone("\{pidfile}.gc")
  })
}

///|
async test "P4 a leader that ignores SIGTERM is killed after the grace" {
  @testkit.serial(() => {
    let dir = @testkit.scratch("p4")
    defer @async.protect_from_cancel(() => @testkit.remove_tree(dir))
    let pidfile = "\{dir}/pid"

    let (result, elapsed) = @testkit.timed(() => {
      describe_run("/bin/sh", [mock("child.sh"), "ignore-term", pidfile])
    })

    assert_eq(result, "started ended=timeout status=1")
    @testkit.assert_between(elapsed, 1200, 2300)
    assert_gone(pidfile)
    assert_gone("\{pidfile}.gc")
  })
}

///|
async test "P5 output past 16 MiB stops the command" {
  @testkit.serial(() => {
    let dir = @testkit.scratch("p5-stop")
    defer @async.protect_from_cancel(() => @testkit.remove_tree(dir))
    let pidfile = "\{dir}/pid"

    let run = run_flood(pidfile)

    assert_eq(run.ended.name(), "output-limit")
    assert_gone(pidfile)
  })
}

///|
async test "P5 output past 16 MiB keeps at most 16 MiB" {
  @testkit.serial(() => {
    let run = run_flood("/dev/null")

    assert_eq(run.ended.name(), "output-limit")
    @testkit.assert_between(
      run.stdout.length() + run.stderr.length(),
      8000001,
      16777216,
    )
  })
}

///|
async test "a command that exits without reading its input is not an error" {
  @testkit.serial(() => {
    let input = String::make(2 * 1024 * 1024, 'x')
    assert_eq(
      describe_run("/usr/bin/true", [], input~),
      "started ended=exit status=0",
    )
  })
}

///|
async test "the environment of a command is exactly the one given" {
  @testkit.serial(() => {
    assert_eq(
      describe_run(
        "/usr/bin/env",
        [],
        env={ "A": "1", "B": "two words" },
        output=true,
      ),
      "started ended=exit status=0 stdout=\"A=1\\nB=two words\\n\" stderr=\"\"",
    )
  })
}

///|
async test "a command runs in the working directory given" {
  @testkit.serial(() => {
    assert_eq(
      describe_run("/bin/pwd", [], cwd="/", output=true),
      "started ended=exit status=0 stdout=\"/\\n\" stderr=\"\"",
    )
  })
}

///|
async test "a bare command name is looked up in the PATH of the given environment" {
  @testkit.serial(() => {
    assert_eq(
      describe_run("sh", ["-c", "exit 4"], env={ "PATH": "/bin" }),
      "started ended=exit status=4",
    )
    let missing = describe_run("sh", ["-c", "exit 4"], env={
      "PATH": "/nonexistent",
    })
    assert_eq(missing, "failed started=false: cannot run sh (ENOENT)")
  })
}

///|
async test "a megabyte of output is read whole" {
  @testkit.serial(() => {
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
  @testkit.serial(() => {
    let results : Array[String] = Array::make(12, "")
    @async.with_task_group(group => {
      for i in 0..<12 {
        group.spawn_bg(() => {
          results[i] = if i % 2 == 0 {
            describe_run("/bin/echo", ["n\{i}"], output=true)
          } else {
            describe_run("/nonexistent/cmd\{i}", [])
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
  @testkit.serial(() => {
    // `cat` sees EOF only when every copy of its stdin's write end is closed, so a sleeper that inherited the parent's end would hold it for as long as it lives.
    let cat_ended = Ref(-1)
    let sleeper_ms = Ref(-1)
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        let (result, ms) = @testkit.timed(() => {
          describe_run("/bin/cat", [], input="hello", output=true)
        })
        assert_eq(
          result, "started ended=exit status=0 stdout=\"hello\" stderr=\"\"",
        )
        cat_ended.val = ms
      })
      group.spawn_bg(() => {
        let (_, ms) = @testkit.timed(() => {
          describe_run("/bin/sleep", ["1.5"], timeout_ms=5000)
        })
        sleeper_ms.val = ms
      })
    })
    @testkit.assert_between(cat_ended.val, 0, 699)
    @testkit.assert_between(sleeper_ms.val, 1400, 5000)
  })
}

///|
async test "a command sees only the descriptors it was given, whatever else is starting" {
  @testkit.serial(() => {
    let alone = describe_run("/bin/ls", ["/dev/fd"], output=true)
    let crowded = Ref("")
    @async.with_task_group(group => {
      group.spawn_bg(() => ignore(describe_run("/bin/cat", [], input="x")))
      group.spawn_bg(() => ignore(describe_run("/bin/sleep", ["0.5"])))
      group.spawn_bg(() => {
        crowded.val = describe_run("/bin/ls", ["/dev/fd"], output=true)
      })
    })
    assert_eq(crowded.val, alone)
  })
}

///|
async test "cancelling a run stops the command and its group" {
  @testkit.serial(() => {
    let dir = @testkit.scratch("cancel")
    defer @async.protect_from_cancel(() => @testkit.remove_tree(dir))
    let pidfile = "\{dir}/pid"

    let finished = @async.with_timeout_opt(300, () => {
      describe_run(
        "/bin/sh",
        [mock("child.sh"), "term-ok", pidfile],
        timeout_ms=30000,
      )
    })

    assert_eq(finished, None)
    assert_gone(pidfile)
    assert_gone("\{pidfile}.gc")
  })
}

///|
async test "cancelling a run closes every descriptor" {
  @testkit.serial(() => {
    let dir = @testkit.scratch("cancel-fds")
    defer @async.protect_from_cancel(() => @testkit.remove_tree(dir))
    let pidfile = "\{dir}/pid"
    // The runtime's own descriptors exist only after a first start, so start once before counting.
    ignore(describe_run("/usr/bin/true", []))
    let before = @testkit.open_fds()

    let finished = @async.with_timeout_opt(300, () => {
      describe_run(
        "/bin/sh",
        [mock("child.sh"), "term-ok", pidfile],
        timeout_ms=30000,
      )
    })

    assert_eq(finished, None)
    assert_eq(@testkit.open_fds(), before)
  })
}

///|
async test "every finished run leaves no descriptor behind" {
  @testkit.serial(() => {
    ignore(describe_run("/usr/bin/true", []))
    let before = @testkit.open_fds()
    ignore(describe_run("/bin/sh", ["-c", "exit 2"]))
    ignore(describe_run("/nonexistent/cmd", []))
    ignore(describe_run("/bin/sleep", ["5"], timeout_ms=200, kill_grace_ms=200))
    assert_eq(@testkit.open_fds(), before)
  })
}

///|
async test "run_command returns the status and output of a failing command" {
  @testkit.serial(() => {
    let ran = run_command("/bin/sh", ["-c", "echo no >&2; exit 3"], plain_env())
    assert_eq(ran.status, 3)
    assert_eq(ran.stdout, "")
    assert_eq(ran.stderr, "no\n")
  })
}

///|
async test "run_command stops a command that runs past the timeout" {
  @testkit.serial(() => {
    assert_eq(
      run_command_failure("/bin/sleep", ["5"], timeout_ms=50),
      "command=/bin/sleep message=/bin/sleep was stopped after 50 ms code=none",
    )
  })
}

///|
async test "run_command reports a command that cannot start with ENOENT" {
  @testkit.serial(() => {
    assert_eq(
      run_command_failure("/nonexistent/cmd", []),
      "command=/nonexistent/cmd message=cannot run /nonexistent/cmd code=ENOENT",
    )
  })
}

///|
async test "run_command reports a command that dies from a signal without a code" {
  @testkit.serial(() => {
    assert_eq(
      run_command_failure("/bin/sh", ["-c", "kill -9 $$"]),
      "command=/bin/sh message=cannot run /bin/sh code=none",
    )
  })
}

///|
async test "run_command ends a command that reads stdin to its end instead of waiting for the timeout" {
  @testkit.serial(() => {
    let ran = run_command("/bin/cat", [], plain_env(), timeout_ms=5000)
    assert_eq(ran.status, 0)
    assert_eq(ran.stdout, "")
  })
}

///|
async test "run_command kills a command that ignores SIGTERM after a grace" {
  @testkit.serial(() => {
    let (result, elapsed) = describe_command_run(
      "trap '' TERM; sleep 5",
      timeout_ms=100,
    )
    assert_eq(
      result, "command=/bin/sh message=/bin/sh was stopped after 100 ms code=none",
    )
    @testkit.assert_between(elapsed, 1000, 2500)
  })
}

///|
async test "run_command stops a grandchild that keeps the output open after the leader exits" {
  @testkit.serial(() => {
    let dir = @testkit.scratch("stop-grandchild")
    defer @async.protect_from_cancel(() => @testkit.remove_tree(dir))
    let pidfile = "\{dir}/pid"
    let (result, elapsed) = describe_command_run(
      "sleep 30 & echo $! > \{pidfile}; exit 0",
      timeout_ms=300,
    )
    assert_eq(
      result, "command=/bin/sh message=/bin/sh was stopped after 300 ms code=none",
    )
    @testkit.assert_between(elapsed, 250, 1500)
    assert_gone(pidfile)
  })
}

///|
async test "run_command gives up on a grandchild that left the group and keeps the output open" {
  @testkit.serial(() => {
    let (result, elapsed) = describe_command_run(
      "perl -MPOSIX -e 'POSIX::setsid(); exec q(sleep), q(4)' & exit 0",
      timeout_ms=300,
    )
    assert_eq(
      mask_pid(result),
      "command=/bin/sh message=/bin/sh did not finish: pid <pid> did not exit after SIGKILL code=none",
    )
    @testkit.assert_between(elapsed, 2000, 3500)
  })
}

///|
async test "run_command closes every descriptor when it gives up on a grandchild" {
  @testkit.serial(() => {
    let before = @testkit.open_fds()

    let (result, _) = describe_command_run(
      "perl -MPOSIX -e 'POSIX::setsid(); exec q(sleep), q(4)' & exit 0",
      timeout_ms=300,
    )

    assert_eq(
      mask_pid(result),
      "command=/bin/sh message=/bin/sh did not finish: pid <pid> did not exit after SIGKILL code=none",
    )
    assert_eq(@testkit.open_fds(), before)
  })
}

///|
async test "cancelling run_command ends the command's group" {
  @testkit.serial(() => {
    let dir = @testkit.scratch("cancel-command")
    defer @async.protect_from_cancel(() => @testkit.remove_tree(dir))
    let pidfile = "\{dir}/pid"

    let finished = @async.with_timeout_opt(300, () => {
      run_command(
        "/bin/sh",
        ["-c", "sleep 30 & echo $! > \{pidfile}; sleep 30"],
        plain_env(),
        timeout_ms=30000,
      )
    })

    assert_eq(finished.map(ran => ran.status), None)
    assert_gone(pidfile)
  })
}

///|
async test "cancelling run_command closes every descriptor" {
  @testkit.serial(() => {
    let dir = @testkit.scratch("cancel-command-fds")
    defer @async.protect_from_cancel(() => @testkit.remove_tree(dir))
    let pidfile = "\{dir}/pid"
    ignore(run_shell("true"))
    let before = @testkit.open_fds()

    let finished = @async.with_timeout_opt(300, () => {
      run_command(
        "/bin/sh",
        ["-c", "sleep 30 & echo $! > \{pidfile}; sleep 30"],
        plain_env(),
        timeout_ms=30000,
      )
    })

    assert_eq(finished.map(ran => ran.status), None)
    assert_eq(@testkit.open_fds(), before)
  })
}

///|
async test "run_command fails on output past 16 MiB" {
  @testkit.serial(() => {
    assert_eq(
      run_command_failure("/usr/bin/yes", [], timeout_ms=20000),
      "command=/usr/bin/yes message=cannot run /usr/bin/yes code=ERR_CHILD_PROCESS_STDIO_MAXBUFFER",
    )
  })
}

///|
async test "run_inherited returns the exit status, and 128 plus the signal for a killed command" {
  @testkit.serial(() => {
    assert_eq(run_inherited("/bin/sh", ["-c", "exit 7"], plain_env()), 7)
    assert_eq(run_inherited("/bin/sh", ["-c", "kill -9 $$"], plain_env()), 137)
  })
}

///|
async test "run_inherited reports a command that cannot start with ENOENT" {
  @testkit.serial(() => {
    let failure = command_failure_of(() => {
      ignore(run_inherited("/nonexistent/cmd", [], plain_env()))
    })

    assert_eq(
      failure, "command=/nonexistent/cmd message=cannot run /nonexistent/cmd code=ENOENT",
    )
  })
}

///|
async test "a command that cannot be stopped makes the run fail as started" {
  @testkit.serial(() => {
    // The grandchild leaves the process group, so only the deadline can end the run, and it keeps the output pipes open.
    let script = "perl -MPOSIX -e 'POSIX::setsid(); exec q(sleep), q(3)' & exit 0"
    let (result, elapsed) = @testkit.timed(() => {
      describe_run("/bin/sh", ["-c", script], timeout_ms=300, kill_grace_ms=200)
    })
    assert_eq(
      mask_pid(result),
      "failed started=true: /bin/sh did not finish: pid <pid> did not exit after SIGKILL",
    )
    @testkit.assert_between(elapsed, 600, 1500)
  })
}

///|
async test "a run that cannot stop a command leaves no descriptor open" {
  @testkit.serial(() => {
    let script = "perl -MPOSIX -e 'POSIX::setsid(); exec q(sleep), q(3)' & exit 0"
    let before = @testkit.open_fds()

    let result = describe_run(
      "/bin/sh",
      ["-c", script],
      timeout_ms=300,
      kill_grace_ms=200,
    )

    assert_eq(
      mask_pid(result),
      "failed started=true: /bin/sh did not finish: pid <pid> did not exit after SIGKILL",
    )
    assert_eq(@testkit.open_fds(), before)
  })
}

///|
async test "B1 cancelling a run whose leader already exited still ends the group" {
  @testkit.serial(() => {
    let dir = @testkit.scratch("b1")
    defer @async.protect_from_cancel(() => @testkit.remove_tree(dir))
    let pidfile = "\{dir}/pid"

    let finished = @async.with_timeout_opt(300, () => {
      describe_run(
        "/bin/sh",
        ["-c", "sleep 30 & echo $! > \{pidfile}; exit 0"],
        timeout_ms=30000,
      )
    })

    assert_eq(finished, None)
    assert_gone(pidfile)
  })
}

///|
async test "B1 cancelling a run whose leader already exited still closes every descriptor" {
  @testkit.serial(() => {
    let dir = @testkit.scratch("b1-fds")
    defer @async.protect_from_cancel(() => @testkit.remove_tree(dir))
    let pidfile = "\{dir}/pid"
    ignore(describe_run("/usr/bin/true", []))
    let before = @testkit.open_fds()

    let finished = @async.with_timeout_opt(300, () => {
      describe_run(
        "/bin/sh",
        ["-c", "sleep 30 & echo $! > \{pidfile}; exit 0"],
        timeout_ms=30000,
      )
    })

    assert_eq(finished, None)
    assert_eq(@testkit.open_fds(), before)
  })
}

///|
async test "B2 run_command counts both streams against one 16 MiB limit" {
  @testkit.serial(() => {
    let (result, _) = describe_command_run(
      "head -c 10000000 /dev/zero; head -c 10000000 /dev/zero >&2",
      timeout_ms=20000,
    )
    assert_eq(
      result, "command=/bin/sh message=cannot run /bin/sh code=ERR_CHILD_PROCESS_STDIO_MAXBUFFER",
    )
  })
}

///|
async test "B3 a relative PATH entry is looked up under the working directory" {
  @testkit.serial(() => {
    let dir = @testkit.scratch("b3")
    defer @async.protect_from_cancel(() => @testkit.remove_tree(dir))
    install_command(dir)

    assert_eq(
      describe_run("hxc-cmd", [], cwd=dir, env={ "PATH": "./bin" }, output=true),
      found_output,
    )
    assert_eq(
      describe_run("hxc-cmd", [], cwd="/", env={ "PATH": "./bin" }),
      "failed started=false: cannot run hxc-cmd (ENOENT)",
    )
  })
}

///|
async test "B3 an empty PATH entry is the working directory" {
  @testkit.serial(() => {
    let dir = @testkit.scratch("b3-empty")
    defer @async.protect_from_cancel(() => @testkit.remove_tree(dir))
    install_command(dir)

    assert_eq(
      describe_run(
        "hxc-cmd",
        [],
        cwd="\{dir}/bin",
        env={ "PATH": "/nonexistent:" },
        output=true,
      ),
      found_output,
    )
  })
}

///|
async test "run_command keeps the error code Node attaches for a command that cannot start or overflows the output" {
  @testkit.serial(() => {
    assert_eq(
      run_command_failure("git-not-here", []),
      "command=git-not-here message=cannot run git-not-here code=ENOENT",
    )
    assert_eq(
      run_command_failure(
        "/bin/sh",
        ["-c", "head -c 17000000 /dev/zero"],
        timeout_ms=20000,
      ),
      "command=/bin/sh message=cannot run /bin/sh code=ERR_CHILD_PROCESS_STDIO_MAXBUFFER",
    )
  })
}

///|
async test "run_command attaches no error code to a timeout or a signal death" {
  @testkit.serial(() => {
    assert_eq(
      run_command_failure("/bin/sleep", ["5"], timeout_ms=50),
      "command=/bin/sleep message=/bin/sleep was stopped after 50 ms code=none",
    )
    assert_eq(
      run_command_failure("/bin/sh", ["-c", "kill -9 $$"]),
      "command=/bin/sh message=cannot run /bin/sh code=none",
    )
  })
}

///|
fn plain_env() -> Map[String, String] {
  { "PATH": "/usr/bin:/bin" }
}

///|
fn mock(name : String) -> String {
  "\{@env.current_dir().unwrap()}/test/native/mocks/\{name}"
}

///|
async fn describe_run(
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
async fn run_shell(script : String) -> String {
  let ran = run_command("/bin/sh", ["-c", script], plain_env())
  ran.stdout
}

///|
async fn wait_until_gone(pid : Int32) -> Bool {
  // A signalled child is collected by init a moment after it dies, so poll instead of checking once.
  for _ in 0..<200 {
    if !@testkit.alive(pid) {
      return true
    }
    @async.sleep(10)
  }
  false
}

///|
async fn read_pid(file : String) -> Int32 {
  @string.parse_int(run_shell("cat \{file}").trim().to_owned()) catch {
    _ => -1
  }
}

///|
fn spawn_missing_with_stdio_closed() -> (Int32, Int32, Int32) raise {
  let saved = @testkit.close_stdio()
  let before = @testkit.open_fds()
  // A print or a wait while descriptors 0 to 2 are closed would hit the test runner's own output, so the synchronous `spawn` is called directly.
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
async fn describe_command_run(
  script : String,
  timeout_ms~ : Int32,
) -> (String, Int32) {
  @testkit.timed(() => {
    run_command_failure("/bin/sh", ["-c", script], timeout_ms~)
  })
}

///|
let found_output : String = "started ended=exit status=0 stdout=\"found\\n\" stderr=\"\""

///|
async fn assert_gone(pidfile : String) -> Unit {
  let pid = read_pid(pidfile)
  assert_true(pid > 0, msg="no pid in \{pidfile}")
  assert_true(wait_until_gone(pid), msg="pid \{pid} from \{pidfile} is alive")
}

///|
async fn run_flood(
  pidfile : String,
) -> @boundary.ProcessRun raise @boundary.ProcessRunFailed {
  run_process(
    "/bin/sh",
    ["-c", "echo $$ > \{pidfile}; exec yes"],
    "",
    cwd="/",
    env=plain_env(),
    timeout_ms=10000,
    kill_grace_ms=500,
  )
}

///|
async fn command_failure_of(
  body : async () -> Unit raise @boundary.CommandFailed,
) -> String {
  try {
    body()
    "no failure"
  } catch {
    @boundary.CommandFailed(command~, message~, code~) =>
      "command=\{command} message=\{message} code=\{code.unwrap_or("none")}"
  }
}

///|
async fn run_command_failure(
  file : String,
  args : Array[String],
  timeout_ms~ : Int32 = 10000,
) -> String {
  command_failure_of(() => {
    ignore(run_command(file, args, plain_env(), timeout_ms~))
  })
}

///|
fn mask_pid(message : String) -> String {
  guard message.find("pid ") is Some(at) else { return message }
  let digits_start = at + 4
  let mut digits_end = digits_start
  while digits_end < message.length() &&
        message.code_unit_at(digits_end).to_int() is (0x30..<=0x39) {
    digits_end += 1
  }
  if digits_end == digits_start {
    return message
  }
  "\{message[:digits_start]}<pid>\{message[digits_end:]}"
}

///|
async fn install_command(dir : String) -> Unit {
  ignore(
    run_shell(
      "mkdir -p \{dir}/bin && printf '#!/bin/sh\\necho found\\n' > \{dir}/bin/hxc-cmd && chmod +x \{dir}/bin/hxc-cmd",
    ),
  )
}
