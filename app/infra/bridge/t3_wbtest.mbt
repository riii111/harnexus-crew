///|
async test "create_thread starts the thread in a new worktree from the starting branch" {
  @testkit.serial(() => {
    with_t3("t3-1", fake => {
      fake.plan(
        1,
        out="{\"threadId\":\"t1\",\"projectId\":\"p1\",\"runId\":\"r1\"}",
      )
      fake.plan(2, out=shown("claude-sonnet-5-5"))

      let answer = t3_json(
        t3_deps(fake),
        "create_thread",
        create_args(
          target=worker_target(
            starting_state=Json::object({
              "type": Json::string("branch"),
              "branchName": Json::string("feat/base"),
            }),
          ),
        ),
      )

      assert_eq(answer, done_answer("t1", "claude-sonnet-5-5"))
      assert_eq(fake.args(1), [
        "thread", "start", "p1", "-", "--title", "T", "--provider", "claudeAgent",
        "--model", "claude-sonnet-5-5", "--worktree", "feat/base", "--json",
      ])
    })
  })
}

///|
async test "create_thread gives the prompt on stdin, even when it looks like a flag" {
  @testkit.serial(() => {
    with_t3("t3-1b", fake => {
      fake.plan(1, out="{\"threadId\":\"t1\"}")
      fake.plan(2, out=shown("claude-sonnet-5-5"))

      let answer = t3_json(
        t3_deps(fake),
        "create_thread",
        create_args(extra=[
          ("prompt", Json::string("--prompt that looks like a flag")),
        ]),
      )

      assert_eq(answer, done_answer("t1", "claude-sonnet-5-5"))
      assert_eq(fake.recorded("stdin", 1), "--prompt that looks like a flag")
      assert_eq(fake.args(1)[3], "-")
    })
  })
}

///|
async test "create_thread runs t3 in the home directory" {
  @testkit.serial(() => {
    with_t3("t3-1c", fake => {
      fake.plan(1, out="{\"threadId\":\"t1\"}")
      fake.plan(2, out=shown("claude-sonnet-5-5"))

      let answer = t3_json(t3_deps(fake), "create_thread", create_args())

      assert_eq(answer, done_answer("t1", "claude-sonnet-5-5"))
      assert_eq(@text.js_trim(fake.recorded("cwd", 1)), fake.root)
    })
  })
}

///|
async test "create_thread reports the model T3 Code shows for the new thread" {
  @testkit.serial(() => {
    with_t3("t3-1d", fake => {
      fake.plan(1, out="{\"threadId\":\"t1\"}")
      fake.plan(2, out=shown("claude-opus-4-8"))

      let answer = t3_json(t3_deps(fake), "create_thread", create_args())

      assert_eq(answer, done_answer("t1", "claude-opus-4-8"))
      assert_eq(fake.args(2), [
        "thread", "show", "t1", "--messages", "0", "--json",
      ])
    })
  })
}

///|
async test "a Codex model is started with the codex provider" {
  @testkit.serial(() => {
    with_t3("t3-2", fake => {
      fake.plan(1, out="{\"threadId\":\"t1\"}")
      fake.plan(2, out=shown("gpt-6.1-sol"))

      let answer = t3_json(
        t3_deps(fake),
        "create_thread",
        create_args(extra=[("model", Json::string("gpt-6.1-sol"))]),
      )

      assert_eq(answer, done_answer("t1", "gpt-6.1-sol"))
      assert_eq(fake.args(1)[6:8].to_owned(), ["--provider", "codex"])
    })
  })
}

///|
async test "a worker without a starting branch starts from HEAD" {
  @testkit.serial(() => {
    with_t3("t3-2b", fake => {
      fake.plan(1, out="{\"threadId\":\"t1\"}")
      fake.plan(2, out=shown("claude-sonnet-5-5"))

      let answer = t3_json(t3_deps(fake), "create_thread", create_args())

      assert_eq(answer, done_answer("t1", "claude-sonnet-5-5"))
      assert_eq(fake.args(1)[10:12].to_owned(), ["--worktree", "HEAD"])
    })
  })
}

///|
async test "a chat outside a worktree starts without naming one" {
  @testkit.serial(() => {
    with_t3("t3-3", fake => {
      fake.plan(1, out="{\"threadId\":\"t1\"}")
      fake.plan(2, out=shown("claude-sonnet-5-5"))
      let target = Json::object({
        "projectId": Json::string("p1"),
        "environment": Json::object({ "type": Json::string("local") }),
      })

      let answer = t3_json(t3_deps(fake), "create_thread", create_args(target~))

      assert_eq(answer, done_answer("t1", "claude-sonnet-5-5"))
      assert_eq(fake.args(1), [
        "thread", "start", "p1", "-", "--title", "T", "--provider", "claudeAgent",
        "--model", "claude-sonnet-5-5", "--json",
      ])
    })
  })
}

///|
async test "a thinking level is refused without running t3" {
  @testkit.serial(() => {
    with_t3("t3-4", fake => {
      for thinking in [Json::string("high"), Json::null()] {
        let answer = t3_json(
          t3_deps(fake),
          "create_thread",
          create_args(extra=[("thinking", thinking)]),
        )

        assert_eq(
          answer,
          failed_json(
            "unsupported", "T3 Code's t3 CLI cannot set a thinking level; leave out --thinking, and set it in T3 Code instead",
          ),
          msg=thinking.stringify(),
        )
      }

      assert_false(fake.ran())
      assert_true(t3_runs_for_valid_create(fake))
    })
  })
}

///|
async test "a failure the CLI says left nothing behind is unsent" {
  @testkit.serial(() => {
    with_t3("t3-5", fake => {
      let failures = [
        (
          "No running T3 Code server uses /x/.t3. Start T3 Code, then retry.", "No running T3 Code server uses /x/.t3. Start T3 Code, then retry.",
        ),
        (
          "No T3 Code project matches '/x/review-home'. Pass a project id or a path inside a project.",
          "No T3 Code project matches '/x/review-home'. Pass a project id or a path inside a project.; add the folder to T3 Code as a project with `t3 project add <path>`",
        ),
        ("No thread was created", "No thread was created"),
        (
          "NetError: Failed to reserve loopback port\n listen EPERM", "NetError: Failed to reserve loopback port\n listen EPERM; run outside the sandbox",
        ),
      ]

      for index, failure in failures {
        let (stderr, error) = failure
        fake.plan(index + 1, exit=1, stderr~)

        let answer = t3_json(t3_deps(fake), "create_thread", create_args())

        assert_eq(answer, failed_json("not_sent", error), msg=stderr)
      }
    })
  })
}

///|
async test "a failure the CLI does not say left nothing behind is unknown" {
  @testkit.serial(() => {
    with_t3("t3-5b", fake => {
      fake.plan(
        1,
        exit=1,
        stderr="Could not reach the T3 Code server at http://127.0.0.1:3773.",
      )

      let answer = t3_json(t3_deps(fake), "create_thread", create_args())

      assert_eq(
        answer,
        failed_json(
          "unknown", "Could not reach the T3 Code server at http://127.0.0.1:3773.",
        ),
      )
    })
  })
}

///|
async test "a failed run with no message reports the exit status" {
  @testkit.serial(() => {
    with_t3("t3-6", fake => {
      fake.plan(1, exit=3)
      let answer = t3_json(t3_deps(fake), "create_thread", create_args())

      assert_eq(
        answer, "{\"outcome\":\"unknown\",\"error\":\"t3 exited with 3\"}",
      )
    })
  })
}

///|
async test "a start that printed no thread is unknown, since a thread may exist" {
  @testkit.serial(() => {
    with_t3("t3-7", fake => {
      let printed = ["Thread started\n", "{\"threadId\":5}"]
      let excerpts = ["Thread started", "{\"threadId\":5}"]

      for index, out in printed {
        fake.plan(index + 1, out~)

        let answer = t3_json(t3_deps(fake), "create_thread", create_args())

        assert_eq(
          answer,
          failed_json(
            "unknown",
            "t3 thread start answered without a thread: \{excerpts[index]}",
          ),
          msg=out,
        )
      }
    })
  })
}

///|
async test "the thread is the last line of the output" {
  @testkit.serial(() => {
    with_t3("t3-8", fake => {
      fake.plan(1, out="starting\n{\"x\":1}\n{\"threadId\":\"t9\"}\n\n")
      fake.plan(2, out="log\n" + shown("m"))
      let answer = t3_json(t3_deps(fake), "create_thread", create_args())

      assert_eq(
        answer, "{\"outcome\":\"done\",\"threadId\":\"t9\",\"model\":\"m\",\"effort\":null}",
      )
    })
  })
}

///|
async test "no model is reported when T3 Code cannot show the thread it started" {
  @testkit.serial(() => {
    with_t3("t3-9", fake => {
      fake.plan(1, out="{\"threadId\":\"t1\"}")
      fake.plan(2, exit=1, stderr="boom")
      let answer = t3_json(t3_deps(fake), "create_thread", create_args())
      assert_eq(
        answer,
        "{\"outcome\":\"done\",\"threadId\":\"t1\",\"model\":null,\"effort\":null}",
        msg="show fails",
      )
      fake.plan(3, out="{\"threadId\":\"t1\"}")
      fake.plan(4, out="{\"thread\":{\"model\":7}}")
      let numeric = t3_json(t3_deps(fake), "create_thread", create_args())
      assert_eq(
        numeric,
        "{\"outcome\":\"done\",\"threadId\":\"t1\",\"model\":null,\"effort\":null}",
        msg="model is a number",
      )
    })
  })
}

///|
async test "create_thread without what it needs sends nothing" {
  @testkit.serial(() => {
    with_t3("t3-10", fake => {
      let refused = [
        ("prompt", create_args_without("prompt")),
        ("title", create_args_without("title")),
        ("model", create_args_without("model")),
        ("project", create_args(target=Json::object({}))),
      ]

      for item in refused {
        let (label, args) = item
        assert_eq(
          t3_json(t3_deps(fake), "create_thread", args),
          failed_json(
            "not_sent", "create_thread needs prompt, title, model and a project",
          ),
          msg=label,
        )
      }

      assert_false(fake.ran())
      assert_true(t3_runs_for_valid_create(fake))
    })
  })
}

///|
async test "an absolute t3 path that cannot be started leaves the call unsent" {
  @testkit.serial(() => {
    with_t3("t3-11", fake => {
      let deps = {
        env: @app_testkit.env_of([
          ("HARNEXUS_T3_BIN", "\{fake.root}/missing"),
          ("HOME", fake.root),
        ]),
        which: _ => None,
      }
      let answer = t3_json(deps, "create_thread", create_args())

      assert_eq(
        answer,
        failed_json(
          "not_sent",
          "cannot run \{fake.root}/missing (ENOENT); install T3 Code, or set HARNEXUS_T3_BIN to its t3 CLI",
        ),
      )
    })
  })
}

///|
async test "a relative t3 path is refused" {
  @testkit.serial(() => {
    with_t3("t3-11b", fake => {
      let relative = {
        env: @app_testkit.env_of([
          ("HARNEXUS_T3_BIN", "t3"),
          ("HOME", fake.root),
        ]),
        which: _ => None,
      }

      assert_eq(
        t3_json(relative, "create_thread", create_args()),
        "{\"outcome\":\"not_sent\",\"error\":\"HARNEXUS_T3_BIN must be an absolute path\"}",
      )
    })
  })
}

///|
async test "a t3 found on PATH is run" {
  @testkit.serial(() => {
    with_t3("t3-12", fake => {
      fake.plan(1, out="{\"threadId\":\"t1\"}")
      fake.plan(2, out=shown("m"))
      let on_path = {
        env: fake.env([("HARNEXUS_T3_BIN", ""), ("PATH", "/usr/bin:/bin")]),
        which: name => if name == "t3" { Some("\{fake.bin}/t3") } else { None },
      }

      let answer = t3_json(on_path, "create_thread", create_args())

      assert_eq(answer, done_answer("t1", "m"))
    })
  })
}

///|
async test "without a t3 on PATH, the t3 in T3 Code's own folder is tried" {
  @testkit.serial(() => {
    with_t3("t3-12b", fake => {
      let in_folder = {
        env: @app_testkit.env_of([
          ("T3CODE_HOME", "\{fake.root}/t3"),
          ("HOME", fake.root),
          ("PATH", "/usr/bin:/bin"),
        ]),
        which: _ => None,
      }

      let answer = t3_json(in_folder, "create_thread", create_args())

      assert_eq(
        answer,
        failed_json(
          "not_sent",
          "cannot run \{fake.root}/t3/bin/t3 (ENOENT); install T3 Code, or set HARNEXUS_T3_BIN to its t3 CLI",
        ),
      )
    })
  })
}

///|
async test "send_message_to_thread queues the prompt on the thread from stdin" {
  @testkit.serial(() => {
    with_t3("t3-13", fake => {
      fake.plan(1, out="{\"delivery\":\"queued\"}")
      let answer = t3_json(t3_deps(fake), "send_message_to_thread", {
        "threadId": Json::string("t1"),
        "prompt": Json::string("re-review"),
      })

      assert_eq(answer, "{\"outcome\":\"done\",\"threadId\":\"t1\"}")
      assert_eq(fake.args(1), ["thread", "send", "t1", "-", "--json"])
      assert_eq(fake.recorded("stdin", 1), "re-review")
    })
  })
}

///|
async test "a send cannot change the model or thinking, so naming either is refused" {
  @testkit.serial(() => {
    with_t3("t3-14", fake => {
      let refusals = [
        (
          "model",
          Json::string("gpt-6.1-sol"),
          "T3 Code's t3 CLI cannot change a thread's model; leave out --model, and change it in T3 Code instead",
        ),
        (
          "thinking",
          Json::string("high"),
          "T3 Code's t3 CLI cannot set a thinking level; leave out --thinking, and set it in T3 Code instead",
        ),
      ]

      for refusal in refusals {
        let (name, value, error) = refusal
        let args : Map[String, Json] = {
          "threadId": Json::string("t1"),
          "prompt": Json::string("p"),
        }
        args[name] = value

        let answer = t3_json(t3_deps(fake), "send_message_to_thread", args)

        assert_eq(answer, failed_json("unsupported", error), msg=name)
      }

      assert_false(fake.ran())
      assert_true(t3_runs_for_valid_create(fake))
    })
  })
}

///|
async test "a send without a thread is refused without running t3" {
  @testkit.serial(() => {
    with_t3("t3-14b", fake => {
      let answer = t3_json(t3_deps(fake), "send_message_to_thread", {
        "prompt": Json::string("p"),
      })

      assert_eq(
        answer,
        failed_json(
          "not_sent", "send_message_to_thread needs threadId and prompt",
        ),
      )
      assert_false(fake.ran())
      assert_true(t3_runs_for_valid_create(fake))
    })
  })
}

///|
async test "a send that fails with a message that left nothing behind is unsent" {
  @testkit.serial(() => {
    with_t3("t3-15", fake => {
      fake.plan(1, exit=1, stderr="No running T3 Code server")
      let args : Map[String, Json] = {
        "threadId": Json::string("t1"),
        "prompt": Json::string("p"),
      }

      let answer = t3_json(t3_deps(fake), "send_message_to_thread", args)

      assert_eq(answer, failed_json("not_sent", "No running T3 Code server"))
    })
  })
}

///|
async test "a send that fails with any other message is unknown" {
  @testkit.serial(() => {
    with_t3("t3-15b", fake => {
      fake.plan(1, exit=1, stderr="Could not reach the server")
      let args : Map[String, Json] = {
        "threadId": Json::string("t1"),
        "prompt": Json::string("p"),
      }

      let answer = t3_json(t3_deps(fake), "send_message_to_thread", args)

      assert_eq(answer, failed_json("unknown", "Could not reach the server"))
    })
  })
}

///|
async test "an operation T3 Code does not offer is unsupported without running t3" {
  @testkit.serial(() => {
    with_t3("t3-16", fake => {
      let answer = t3_json(t3_deps(fake), "name_thread", {
        "name": Json::string("x"),
      })

      assert_eq(
        answer,
        failed_json("unsupported", "T3 Code does not offer name_thread"),
      )
      assert_false(fake.ran())
      assert_true(t3_runs_for_valid_create(fake))
    })
  })
}

///|
async test "a run past its deadline is stopped and reported as unknown" {
  @testkit.serial(() => {
    with_t3("t3-17", fake => {
      fake.plan(1, sleep="30")

      let (ran, elapsed) = @testkit.timed(() => {
        run_t3(t3_deps(fake), ["thread", "send", "t1", "-", "--json"], "p", 150)
      })

      match ran {
        Refused(answer) =>
          assert_eq(
            json_text(answer.to_json()),
            "{\"outcome\":\"unknown\",\"error\":\"no answer: t3 thread send ended by timeout\"}",
          )
        Ran(_) => fail("a run that timed out is not a success")
      }

      @testkit.assert_between(elapsed, 0, 5000)
    })
  })
}

///|
test "a worktree with a starting branch is based on that branch" {
  let environment = Json::object({
    "type": Json::string("worktree"),
    "startingState": Json::object({ "branchName": Json::string("feat/x") }),
  })

  assert_eq(worktree_base({ "environment": environment }), Some("feat/x"))
}

///|
test "a worktree without a usable starting branch is based on HEAD" {
  let environments = [
    Json::object({ "type": Json::string("worktree") }),
    Json::object({
      "type": Json::string("worktree"),
      "startingState": Json::object({ "branchName": Json::number(1.0) }),
    }),
  ]

  for environment in environments {
    assert_eq(
      worktree_base({ "environment": environment }),
      Some("HEAD"),
      msg=environment.stringify(),
    )
  }
}

///|
test "only a worktree environment has a base" {
  let worktree = Json::object({ "type": Json::string("worktree") })
  assert_eq(worktree_base({ "environment": worktree }), Some("HEAD"))
  let others = [
    Json::string("worktree"),
    Json::object({ "type": Json::string("local") }),
  ]

  for environment in others {
    assert_eq(
      worktree_base({ "environment": environment }),
      None,
      msg=environment.stringify(),
    )
  }

  assert_eq(worktree_base({}), None)
}

///|
async fn t3_json(
  deps : T3Deps,
  tool : String,
  args : Map[String, Json],
) -> String {
  json_text(dispatch_tool(deps, tool, args).to_json())
}

///|
fn worker_target(starting_state? : Json) -> Json {
  let environment = { "type": Json::string("worktree") }

  if starting_state is Some(state) {
    environment["startingState"] = state
  }

  Json::object({
    "type": Json::string("project"),
    "projectId": Json::string("p1"),
    "environment": Json::object(environment),
  })
}

///|
fn create_args(
  target? : Json,
  extra? : Array[(String, Json)],
) -> Map[String, Json] {
  let args : Map[String, Json] = {
    "prompt": Json::string("p"),
    "target": target.unwrap_or(worker_target()),
    "title": Json::string("T"),
    "model": Json::string("claude-sonnet-5-5"),
  }

  for pair in extra.unwrap_or([]) {
    let (name, value) = pair
    args[name] = value
  }

  args
}

///|
fn shown(model : String) -> String {
  "{\"thread\":{\"threadId\":\"t1\",\"model\":\"\{model}\"},\"messages\":[]}"
}

///|
async fn with_t3(
  name : String,
  body : async (@app_testkit.FakeCli) -> Unit,
) -> Unit {
  @app_testkit.with_fake_cli(name, mock="fake-cli.sh", stand_ins=["t3"], body)
}

///|
fn t3_deps(fake : @app_testkit.FakeCli) -> T3Deps {
  {
    env: fake.env([
      ("HARNEXUS_T3_BIN", "\{fake.bin}/t3"),
      ("PATH", "/usr/bin:/bin"),
    ]),
    which: _ => None,
  }
}

///|
async fn t3_runs_for_valid_create(fake : @app_testkit.FakeCli) -> Bool {
  fake.plan(1, out="{\"threadId\":\"t1\"}")
  ignore(t3_json(t3_deps(fake), "create_thread", create_args()))
  fake.ran()
}

///|
fn done_answer(thread_id : String, model : String) -> String {
  "{\"outcome\":\"done\",\"threadId\":\"\{thread_id}\",\"model\":\"\{model}\",\"effort\":null}"
}

///|
fn create_args_without(name : String) -> Map[String, Json] {
  let args = create_args()
  args.remove(name)
  args
}
