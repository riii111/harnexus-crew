///|
const BASE : String = "1111111111111111111111111111111111111111"

///|
const HEAD_1 : String = "2222222222222222222222222222222222222222"

///|
const HEAD_2 : String = "3333333333333333333333333333333333333333"

///|
const OTHER : String = "01a18d52-e03a-74c1-a50e-4e697b47172c"

///|
fn temp_base() -> String {
  let base = @env.get_env_var("TMPDIR").unwrap_or("/tmp")
  if base.has_suffix("/") {
    base[:base.length() - 1].to_owned()
  } else {
    base
  }
}

///|
async fn remove_tree(directory : String) -> Unit {
  ignore(
    @process.run_command("rm", ["-rf", directory], { "PATH": "/usr/bin:/bin" }) catch {
      _ => abort("cannot remove \{directory}")
    },
  )
}

///|
fn write_text(path : String, text : String) -> Unit {
  @store.prepare_directory(@path.dirname(path)) catch {
    failed => abort(failed.user_message())
  }
  @store.write_atomic(path, text) catch {
    failed => abort(failed.user_message())
  }
}

///|
/// What a test of a cloud review works with: a scratch root with a checkout and a stand-in for the Codex CLI.
struct Rig {
  root : String
  /// Where the stand-in for the Codex CLI keeps what each of its runs was given.
  fake : String
  checkout : String
  /// The commit the checkout is at.
  head : Ref[String]
  /// A record whose path ends so cannot be written.
  unwritable : Ref[String?]
  /// The values the reviewer template was filled with.
  prompts : Array[Map[String, String]]
}

///|
async fn with_rig(name : String, body : async (Rig) -> Unit) -> Unit {
  let made = "\{temp_base()}/hxc-\{@testkit.pid()}-\{name}-\{@store.new_uuid()[:8]}"
  @store.prepare_directory("\{made}/repo") catch {
    failed => abort(failed.user_message())
  }
  @store.prepare_directory("\{made}/fake") catch {
    failed => abort(failed.user_message())
  }
  let root = @store.real_path_or_self(made)
  errdefer @async.protect_from_cancel(() => remove_tree(root))
  body({
    root,
    fake: "\{root}/fake",
    checkout: "\{root}/repo",
    head: Ref(HEAD_1),
    unwritable: Ref(None),
    prompts: [],
  })
  remove_tree(root)
}

///|
fn Rig::env(self : Rig, extra : Array[(String, String)]) -> @environment.Env {
  let vars = Map([])
  vars["HOME"] = self.root
  vars["XDG_STATE_HOME"] = "\{self.root}/state"
  vars["PATH"] = @env.get_env_var("PATH").unwrap_or("/usr/bin:/bin")
  vars["CLAUDE_CODE_REMOTE"] = "true"
  vars["CLAUDE_CODE_SESSION_ID"] = "worker-session"
  vars["HARNEXUS_CODEX_BIN"] = "\{@env.current_dir().unwrap()}/test/native/mocks/fake-cli.sh"
  vars["FAKE_DIR"] = self.fake
  for pair in extra {
    let (name, value) = pair
    vars[name] = value
  }
  @environment.Env::new(vars)
}

///|
/// The context of a run: Git is at the rig's head, the template and the unwritable records are stand-ins, and the Codex CLI is the fake.
fn Rig::context(self : Rig, extra : Array[(String, String)]) -> Context {
  let env = self.env(extra)
  let checkout = self.checkout
  let head = self.head
  {
    env,
    probe: {
      path_exists: _ => true,
      is_directory: _ => true,
      real_path_or_self: path => path,
    },
    git: @request.Git::new(
      {
        run: (argv, _) => {
          let words = argv.join(" ")
          let after = words
            .find("-C \{checkout} ")
            .map(at => at + checkout.length() + 4)
            .unwrap_or(0)
          let out = match words[after:].to_owned() {
            "rev-parse --show-toplevel" => checkout
            "rev-parse HEAD" => head.val
            "rev-parse --symbolic-full-name --verify --end-of-options base" =>
              "refs/heads/base"
            "rev-parse --verify refs/heads/base^{commit}" => BASE
            other if other.has_prefix("merge-base ") =>
              other.split(" ").collect()[1].to_owned()
            other => abort("git was asked for \{other}")
          }
          { status: 0, stdout: "\{out}\n", stderr: "", }
        },
      },
      env,
    ),
    prompt: fields => {
      self.prompts.push(fields)
      "reviewer prompt for \{fields.get("task_id").unwrap_or("?")} at \{fields.get("head").unwrap_or("?")}"
    },
    save: (path, data) => {
      if self.unwritable.val is Some(suffix) && path.has_suffix(suffix) {
        @failure.fail("cannot write \{path}")
      }
      @store.save_json(path, data, exclusive=false)
    },
  }
}

///|
fn Rig::state_dir(self : Rig, task_id : String) -> String {
  @store.state_directory(
    "\{self.root}/state/harnexus-crew",
    "cloud-review",
    "\{self.checkout}\u{0}\{task_id}",
  )
}

///|
fn Rig::request_file(
  self : Rig,
  task~ : String = "example",
  extra? : String,
) -> String {
  let path = "\{self.root}/review.json"
  write_text(
    path,
    "{\"taskId\":\"\{task}\",\"workerAI\":\"Claude\",\"checkout\":\"\{self.checkout}\",\"baseBranch\":\"base\",\"documentRefs\":[\"https://example.com/task\"],\"prUrl\":null\{extra.unwrap_or("")}}",
  )
  path
}

///|
fn parsed_review(extra : Array[String]) -> @args.ReviewArgs {
  match
    (@args.parse_command("review", extra[:]) catch {
      _ => abort("bad arguments")
    }) {
    Run(Review(args)) => args
    _ => abort("not a review")
  }
}

///|
/// Runs `review` for the rig's request with the options given.
async fn Rig::review(
  self : Rig,
  extra~ : Array[String] = [],
  env~ : Array[(String, String)] = [],
  task~ : String = "example",
  request? : String,
) -> Json raise @failure.TaskFailed {
  let path = self.request_file(task~, extra?=request)
  let argv = ["--request", path]
  argv.append(extra)
  review_in(self.context(env), parsed_review(argv))
}

///|
async fn failure_of(
  work : async () -> Unit raise @failure.TaskFailed,
) -> String {
  try {
    work()
    ""
  } catch {
    failed => failed.message()
  }
}

///|
/// The message a review failed with, "" when it succeeded.
async fn Rig::review_failure(
  self : Rig,
  extra~ : Array[String] = [],
  env~ : Array[(String, String)] = [],
  task~ : String = "example",
) -> String {
  failure_of(() => ignore(self.review(extra~, env~, task~)))
}

///|
fn events(thread : String, answer : String) -> String {
  [
    Json::object({
      "type": Json::string("thread.started"),
      "thread_id": Json::string(thread),
    }),
    Json::object({ "type": Json::string("turn.started") }),
    Json::object({
      "type": Json::string("item.completed"),
      "item": Json::object({
        "id": Json::string("item_0"),
        "type": Json::string("agent_message"),
        "text": Json::string(answer),
      }),
    }),
    Json::object({ "type": Json::string("turn.completed") }),
  ]
  .map(value => value.stringify())
  .join("\n")
}

///|
fn Rig::plan(
  self : Rig,
  run : Int32,
  out~ : String = "",
  exit~ : Int32 = 0,
  stderr? : String,
  sleep? : String,
) -> Unit {
  write_text("\{self.fake}/out.\{run}", out)
  write_text("\{self.fake}/exit.\{run}", exit.to_string())
  if stderr is Some(text) {
    write_text("\{self.fake}/stderr.\{run}", text)
  }
  if sleep is Some(seconds) {
    write_text("\{self.fake}/sleep.\{run}", seconds)
  }
}

///|
fn Rig::runs(self : Rig) -> Int32 {
  let mut count = 0
  while @store.path_exists("\{self.fake}/args.\{count + 1}") {
    count += 1
  }
  count
}

///|
fn read_state(path : String) -> Json {
  @store.load(path) catch {
    failed => abort(failed.message())
  }
}

///|
fn show(json : Json) -> String {
  json.stringify()
}

///|
fn Rig::pending_exists(self : Rig, task_id : String) -> Bool {
  @store.path_exists("\{self.state_dir(task_id)}/pending.json")
}
