///|
struct Fake {
  root : String
  fake : String
  bin : String
}

///|
fn mock_bin() -> String {
  "\{@env.current_dir().unwrap()}/test/native/mocks/fake-cli.sh"
}

///|
async fn with_fake(name : String, body : async (Fake) -> Unit) -> Unit {
  let root = scratch(name)
  let fake = "\{root}/fake"
  @store.prepare_directory(fake) catch {
    failed => abort(failed.user_message())
  }
  errdefer @async.protect_from_cancel(() => remove_tree(root))
  body({ root, fake, bin: mock_bin(), })
  remove_tree(root)
}

///|
fn Fake::plan(
  self : Fake,
  run : Int32,
  out~ : String = "",
  exit~ : Int32 = 0,
  stderr? : String,
  sleep? : String,
) -> Unit {
  write_file("\{self.fake}/out.\{run}", out)
  write_file("\{self.fake}/exit.\{run}", exit.to_string())
  if stderr is Some(text) {
    write_file("\{self.fake}/stderr.\{run}", text)
  }
  if sleep is Some(seconds) {
    write_file("\{self.fake}/sleep.\{run}", seconds)
  }
}

///|
fn write_file(path : String, text : String) -> Unit {
  @store.write_atomic(path, text) catch {
    failed => abort(failed.user_message())
  }
}

///|
fn Fake::recorded(self : Fake, name : String, run : Int32) -> String {
  let found = @store.read_text_if_exists("\{self.fake}/\{name}.\{run}") catch {
    failed => abort(failed.user_message())
  }
  found.unwrap_or("")
}

///|
fn Fake::args(self : Fake, run : Int32) -> Array[String] {
  let lines = []
  for line in @text.js_trim(self.recorded("args", run)).split("\n") {
    lines.push(line.to_owned())
  }
  lines
}

///|
/// Whether t3 was run at all.
fn Fake::ran(self : Fake) -> Bool {
  @store.path_exists("\{self.fake}/count")
}

///|
fn Fake::deps(self : Fake) -> T3Deps {
  {
    env: env_of([
      ("HARNEXUS_T3_BIN", self.bin),
      ("FAKE_DIR", self.fake),
      ("HOME", self.root),
      ("PATH", "/usr/bin:/bin"),
    ]),
    which: _ => None,
  }
}

///|
async fn t3_json(
  deps : T3Deps,
  tool : String,
  args : Map[String, Json],
) -> String {
  json_text(call_t3(deps, tool, args).to_json())
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
async test "create_thread starts the thread in a new worktree with the prompt on stdin and reports the model T3 Code shows" {
  serial(() => {
    with_fake("t3-1", fake => {
      fake.plan(
        1,
        out="{\"threadId\":\"t1\",\"projectId\":\"p1\",\"runId\":\"r1\"}",
      )
      fake.plan(2, out=shown("claude-sonnet-5-5"))
      let answer = t3_json(
        fake.deps(),
        "create_thread",
        create_args(
          target=worker_target(
            starting_state=Json::object({
              "type": Json::string("branch"),
              "branchName": Json::string("feat/base"),
            }),
          ),
          extra=[("prompt", Json::string("--prompt that looks like a flag"))],
        ),
      )
      assert_eq(
        answer, "{\"outcome\":\"done\",\"threadId\":\"t1\",\"model\":\"claude-sonnet-5-5\",\"effort\":null}",
      )
      assert_eq(fake.args(1), [
        "thread", "start", "p1", "-", "--title", "T", "--provider", "claudeAgent",
        "--model", "claude-sonnet-5-5", "--worktree", "feat/base", "--json",
      ])
      assert_eq(fake.recorded("stdin", 1), "--prompt that looks like a flag")
      assert_eq(fake.args(2), [
        "thread", "show", "t1", "--messages", "0", "--json",
      ])
      assert_eq(
        @text.js_trim(fake.recorded("cwd", 1)),
        @store.real_path_or_self(fake.root),
      )
    })
  })
}

///|
async test "a Codex model is started with the codex provider and a worker without a starting branch from HEAD" {
  serial(() => {
    with_fake("t3-2", fake => {
      fake.plan(1, out="{\"threadId\":\"t1\"}")
      fake.plan(2, out=shown("gpt-6.1-sol"))
      let answer = t3_json(
        fake.deps(),
        "create_thread",
        create_args(extra=[("model", Json::string("gpt-6.1-sol"))]),
      )
      assert_eq(
        answer, "{\"outcome\":\"done\",\"threadId\":\"t1\",\"model\":\"gpt-6.1-sol\",\"effort\":null}",
      )
      let args = fake.args(1)
      assert_eq(args[6:8].to_owned(), ["--provider", "codex"])
      assert_eq(args[10:12].to_owned(), ["--worktree", "HEAD"])
    })
  })
}

///|
async test "a chat outside a worktree starts without naming one" {
  serial(() => {
    with_fake("t3-3", fake => {
      fake.plan(1, out="{\"threadId\":\"t1\"}")
      fake.plan(2, out=shown("m"))
      let target = Json::object({
        "projectId": Json::string("p1"),
        "environment": Json::object({ "type": Json::string("local") }),
      })
      ignore(t3_json(fake.deps(), "create_thread", create_args(target~)))
      assert_false(fake.args(1).contains("--worktree"))
    })
  })
}

///|
async test "a thinking level is refused without running t3" {
  serial(() => {
    with_fake("t3-4", fake => {
      let answer = t3_json(
        fake.deps(),
        "create_thread",
        create_args(extra=[("thinking", Json::string("high"))]),
      )
      assert_eq(
        answer, "{\"outcome\":\"unsupported\",\"error\":\"T3 Code's t3 CLI cannot set a thinking level; leave out --thinking, and set it in T3 Code instead\"}",
      )
      assert_false(fake.ran())
      let null_thinking = t3_json(
        fake.deps(),
        "create_thread",
        create_args(extra=[("thinking", Json::null())]),
      )
      assert_true(null_thinking.contains("\"outcome\":\"unsupported\""))
      assert_false(fake.ran())
    })
  })
}

///|
async test "a failure is unsent only when the CLI says it left nothing behind" {
  for
    failure in [
      (
        "No running T3 Code server uses /x/.t3. Start T3 Code, then retry.", "not_sent",
        "No running T3 Code server uses /x/.t3. Start T3 Code, then retry.\"}",
      ),
      (
        "No T3 Code project matches '/x/review-home'. Pass a project id or a path inside a project.",
        "not_sent", "; add the folder to T3 Code as a project with `t3 project add <path>`\"}",
      ),
      ("No thread was created", "not_sent", "No thread was created\"}"),
      (
        "NetError: Failed to reserve loopback port\n listen EPERM", "not_sent", "; run outside the sandbox\"}",
      ),
      (
        "Could not reach the T3 Code server at http://127.0.0.1:3773.", "unknown",
        "Could not reach the T3 Code server at http://127.0.0.1:3773.\"}",
      ),
    ] {
    let (stderr, outcome, ending) = failure
    serial(() => {
      with_fake("t3-5", fake => {
        fake.plan(1, exit=1, stderr~)
        let answer = t3_json(fake.deps(), "create_thread", create_args())
        assert_true(answer.has_prefix("{\"outcome\":\"\{outcome}\",\"error\":"))
        assert_true(answer.has_suffix(ending))
      })
    })
  }
}

///|
async test "a failed run with no message reports the exit status" {
  serial(() => {
    with_fake("t3-6", fake => {
      fake.plan(1, exit=3)
      let answer = t3_json(fake.deps(), "create_thread", create_args())
      assert_eq(
        answer, "{\"outcome\":\"unknown\",\"error\":\"t3 exited with 3\"}",
      )
    })
  })
}

///|
async test "a start that printed no thread is unknown, since a thread may exist" {
  serial(() => {
    with_fake("t3-7", fake => {
      fake.plan(1, out="Thread started\n")
      let answer = t3_json(fake.deps(), "create_thread", create_args())
      assert_eq(
        answer, "{\"outcome\":\"unknown\",\"error\":\"t3 thread start answered without a thread: Thread started\"}",
      )
      fake.plan(2, out="{\"threadId\":5}")
      let numeric = t3_json(fake.deps(), "create_thread", create_args())
      assert_true(
        numeric.contains("answered without a thread: {\\\"threadId\\\":5}"),
      )
    })
  })
}

///|
async test "the thread is the last line of the output" {
  serial(() => {
    with_fake("t3-8", fake => {
      fake.plan(1, out="starting\n{\"x\":1}\n{\"threadId\":\"t9\"}\n\n")
      fake.plan(2, out="log\n" + shown("m"))
      let answer = t3_json(fake.deps(), "create_thread", create_args())
      assert_eq(
        answer, "{\"outcome\":\"done\",\"threadId\":\"t9\",\"model\":\"m\",\"effort\":null}",
      )
    })
  })
}

///|
async test "no model is reported when T3 Code cannot show the thread it started" {
  serial(() => {
    with_fake("t3-9", fake => {
      fake.plan(1, out="{\"threadId\":\"t1\"}")
      fake.plan(2, exit=1, stderr="boom")
      let answer = t3_json(fake.deps(), "create_thread", create_args())
      assert_eq(
        answer, "{\"outcome\":\"done\",\"threadId\":\"t1\",\"model\":null,\"effort\":null}",
      )
      fake.plan(3, out="{\"threadId\":\"t1\"}")
      fake.plan(4, out="{\"thread\":{\"model\":7}}")
      let numeric = t3_json(fake.deps(), "create_thread", create_args())
      assert_true(numeric.contains("\"model\":null"))
    })
  })
}

///|
async test "create_thread without what it needs sends nothing" {
  serial(() => {
    with_fake("t3-10", fake => {
      for missing in ["prompt", "title", "model"] {
        let args = create_args()
        args.remove(missing)
        assert_eq(
          t3_json(fake.deps(), "create_thread", args),
          "{\"outcome\":\"not_sent\",\"error\":\"create_thread needs prompt, title, model and a project\"}",
        )
      }
      let no_project = create_args(target=Json::object({}))
      assert_true(
        t3_json(fake.deps(), "create_thread", no_project).contains(
          "needs prompt",
        ),
      )
      assert_false(fake.ran())
    })
  })
}

///|
async test "nothing is sent when the t3 CLI cannot start" {
  serial(() => {
    with_fake("t3-11", fake => {
      let deps = {
        env: env_of([
          ("HARNEXUS_T3_BIN", "\{fake.root}/missing"),
          ("HOME", fake.root),
        ]),
        which: _ => None,
      }
      let answer = parse(t3_json(deps, "create_thread", create_args()))
      assert_true(json_text(answer).has_prefix("{\"outcome\":\"not_sent\""))
      assert_true(json_text(answer).contains("HARNEXUS_T3_BIN"))
      let relative = {
        env: env_of([("HARNEXUS_T3_BIN", "t3"), ("HOME", fake.root)]),
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
async test "the t3 CLI is found on PATH first and then in T3 Code's own folder" {
  serial(() => {
    with_fake("t3-12", fake => {
      fake.plan(1, out="{\"threadId\":\"t1\"}")
      fake.plan(2, out=shown("m"))
      let on_path = {
        env: env_of([
          ("HARNEXUS_T3_BIN", ""),
          ("FAKE_DIR", fake.fake),
          ("HOME", fake.root),
          ("PATH", "/usr/bin:/bin"),
        ]),
        which: name => if name == "t3" { Some(fake.bin) } else { None },
      }
      assert_true(
        t3_json(on_path, "create_thread", create_args()).contains(
          "\"threadId\":\"t1\"",
        ),
      )
      let in_folder = {
        env: env_of([
          ("T3CODE_HOME", "\{fake.root}/t3"),
          ("HOME", fake.root),
          ("PATH", "/usr/bin:/bin"),
        ]),
        which: _ => None,
      }
      let answer = t3_json(in_folder, "create_thread", create_args())
      assert_true(answer.has_prefix("{\"outcome\":\"not_sent\""))
      assert_true(answer.contains("\{fake.root}/t3/bin/t3"))
      assert_true(
        answer.contains("install T3 Code, or set HARNEXUS_T3_BIN to its t3 CLI"),
      )
    })
  })
}

///|
async test "send_message_to_thread queues the prompt on the thread from stdin" {
  serial(() => {
    with_fake("t3-13", fake => {
      fake.plan(1, out="{\"delivery\":\"queued\"}")
      let answer = t3_json(fake.deps(), "send_message_to_thread", {
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
  serial(() => {
    with_fake("t3-14", fake => {
      for
        extra in [
          ("model", Json::string("gpt-6.1-sol")),
          ("thinking", Json::string("high")),
        ] {
        let args : Map[String, Json] = {
          "threadId": Json::string("t1"),
          "prompt": Json::string("p"),
        }
        let (name, value) = extra
        args[name] = value
        let answer = t3_json(fake.deps(), "send_message_to_thread", args)
        assert_true(answer.has_prefix("{\"outcome\":\"unsupported\""))
      }
      assert_false(fake.ran())
      assert_eq(
        t3_json(fake.deps(), "send_message_to_thread", {
          "prompt": Json::string("p"),
        }),
        "{\"outcome\":\"not_sent\",\"error\":\"send_message_to_thread needs threadId and prompt\"}",
      )
    })
  })
}

///|
async test "a send that fails is classified like a start" {
  serial(() => {
    with_fake("t3-15", fake => {
      fake.plan(1, exit=1, stderr="No running T3 Code server")
      fake.plan(2, exit=1, stderr="Could not reach the server")
      let args : Map[String, Json] = {
        "threadId": Json::string("t1"),
        "prompt": Json::string("p"),
      }
      assert_eq(
        t3_json(fake.deps(), "send_message_to_thread", args),
        "{\"outcome\":\"not_sent\",\"error\":\"No running T3 Code server\"}",
      )
      assert_eq(
        t3_json(fake.deps(), "send_message_to_thread", args),
        "{\"outcome\":\"unknown\",\"error\":\"Could not reach the server\"}",
      )
    })
  })
}

///|
async test "T3 Code offers no other App operation" {
  serial(() => {
    with_fake("t3-16", fake => {
      assert_eq(
        t3_json(fake.deps(), "name_thread", { "name": Json::string("x") }),
        "{\"outcome\":\"unsupported\",\"error\":\"T3 Code does not offer name_thread\"}",
      )
      assert_false(fake.ran())
    })
  })
}

///|
async test "a run past its deadline is unknown, and nothing is claimed about what t3 did" {
  serial(() => {
    with_fake("t3-17", fake => {
      fake.plan(1, sleep="30")
      let started = @async.now()
      let ran = run_t3(
        fake.deps(),
        ["thread", "send", "t1", "-", "--json"],
        "p",
        150,
      )
      match ran {
        Refused(answer) =>
          assert_eq(
            json_text(answer.to_json()),
            "{\"outcome\":\"unknown\",\"error\":\"no answer: t3 thread send ended by timeout\"}",
          )
        Ran(_) => fail("a run that timed out is not a success")
      }
      assert_true(@async.now() - started < 5000)
    })
  })
}

///|
test "the worktree base is the starting branch, else HEAD, and none outside a worktree" {
  let state = Json::object({ "branchName": Json::string("feat/x") })
  let target = fn(environment : Json) -> Map[String, Json] {
    { "environment": environment }
  }
  assert_true(
    worktree_base(
      target(
        Json::object({
          "type": Json::string("worktree"),
          "startingState": state,
        }),
      ),
    ) ==
    Some("feat/x"),
  )
  assert_true(
    worktree_base(target(Json::object({ "type": Json::string("worktree") }))) ==
    Some("HEAD"),
  )
  assert_true(
    worktree_base(
      target(
        Json::object({
          "type": Json::string("worktree"),
          "startingState": Json::object({ "branchName": Json::number(1.0) }),
        }),
      ),
    ) ==
    Some("HEAD"),
  )
  assert_true(worktree_base(target(Json::string("worktree"))) is None)
  assert_true(worktree_base({}) is None)
}
