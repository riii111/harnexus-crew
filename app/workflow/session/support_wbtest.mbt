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
/// What a test of a session command works with: a scratch root, and the calls the app was asked for.
struct Rig {
  root : String
  /// The app's answers, taken in order; a call past the last gets `not_sent`.
  answers : Array[@bridge.CallAnswer]
  /// Every call made to the app: caller, tool and arguments.
  calls : Array[(String, String, Map[String, Json])]
  /// Runs before a record is written, with its path and whether it must not exist yet; it may write files or fail.
  mut before_save : (String, Bool) -> Unit raise @failure.TaskFailed
  /// The commit the checkout is at.
  head : Ref[String]
  /// Where the worker's checkout is, which depends on the app.
  mut checkout_path : String
  /// What pr-wake printed for the last link.
  linked : Ref[Map[String, Json]?]
  /// The arguments pr-wake was run with.
  pr_wake_calls : Array[Array[String]]
  /// The kind of each prompt template filled and the reply it was filled for, as `kind:reply_to`.
  prompts : Array[String]
}

///|
const BASE : String = "1111111111111111111111111111111111111111"

///|
const HEAD_1 : String = "2222222222222222222222222222222222222222"

///|
const HEAD_2 : String = "3333333333333333333333333333333333333333"

///|
async fn remove_tree(directory : String) -> Unit {
  ignore(
    @process.run_command("rm", ["-rf", directory], { "PATH": "/usr/bin:/bin" }) catch {
      _ => abort("cannot remove \{directory}")
    },
  )
}

///|
/// Runs `body` with a scratch root that is removed afterwards.
async fn with_rig(
  name : String,
  answers : Array[@bridge.CallAnswer],
  body : async (Rig) -> Unit,
) -> Unit {
  let made = "\{temp_base()}/hxs-\{@testkit.pid()}-\{name}-\{@store.new_uuid()[:8]}"
  @store.prepare_directory(made) catch {
    failed => abort(failed.user_message())
  }
  let root = @store.resolve_real_path_or_self(made)
  errdefer @async.protect_from_cancel(() => remove_tree(root))
  let rig = {
    root,
    answers,
    calls: [],
    before_save: (_, _) => (),
    head: Ref(HEAD_1),
    checkout_path: "\{root}/codex/worktrees/ab12/repo",
    linked: Ref(None),
    pr_wake_calls: [],
    prompts: [],
  }
  body(rig)
  remove_tree(root)
}

///|
fn Rig::env(self : Rig, extra : Array[(String, String)]) -> @environment.Env {
  let vars = Map([])
  vars["HOME"] = self.root
  vars["XDG_STATE_HOME"] = "\{self.root}/state"
  vars["CODEX_HOME"] = "\{self.root}/codex"
  vars["CODEX_THREAD_ID"] = "w1"
  for pair in extra {
    let (name, value) = pair
    vars[name] = value
  }
  @environment.Env::new(vars)
}

///|
fn Rig::checkout(self : Rig) -> String {
  self.checkout_path
}

///|
fn Rig::state_dir(self : Rig, kind : String, key : String) -> String {
  @store.state_directory("\{self.root}/state/harnexus-crew", kind, key)
}

///|
/// The context of a run: the app answers from the rig's list, Git is at the rig's head, and the templates and pr-wake are stand-ins.
fn Rig::context(self : Rig, extra : Array[(String, String)]) -> Context {
  let env = self.env(extra)
  let host = @host.host_of(env, which=_ => None)
  let checkout = self.checkout()
  let head = self.head
  let ports : Ports = {
    call: (caller, tool, args) => {
      self.calls.push((caller, tool, args))
      if self.answers.is_empty() {
        @bridge.CallAnswer::failed(NotSent, error="no answer planned")
      } else {
        self.answers.remove(0)
      }
    },
    save: (path, data, exclusive) => {
      (self.before_save)(path, exclusive)
      @store.save_json(path, data, exclusive~)
    },
  }
  {
    env,
    host,
    ports,
    review_project: match @environment.app_of(env) {
      T3 => host.review_project
      Codex => _ => "p-review"
    },
    probe: {
      path_exists: _ => true,
      is_directory: _ => true,
      resolve_real_path_or_self: path => path,
    },
    git: @git.Git::new(
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
            "rev-parse --symbolic-full-name --verify --end-of-options other" =>
              "refs/heads/other"
            "rev-parse --verify refs/heads/base^{commit}" => BASE
            "rev-parse --verify refs/heads/other^{commit}" => HEAD_1
            other if other.has_prefix("merge-base ") =>
              other.split(" ").collect()[1].to_owned()
            other => abort("git was asked for \{other}")
          }
          { status: 0, stdout: "\{out}\n", stderr: "", }
        },
      },
      env,
    ),
    prompt: (kind, fields) => {
      let name = match kind {
        Worker => "worker"
        Reviewer => "reviewer"
      }
      self.prompts.push("\{name}:\{fields.get("reply_to").unwrap_or("-")}")
      "\{name} prompt for \{fields.get("task_id").unwrap_or("?")}"
    },
    pr_wake: args => {
      self.pr_wake_calls.push(args)
      match self.linked.val {
        Some(printed) => printed
        None => @failure.fail("pr-wake is not set up")
      }
    },
  }
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
fn read_state(path : String) -> Json {
  @store.read_json_or_null(path) catch {
    failed => abort(failed.message())
  }
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
fn done(
  thread : String,
  model? : String,
  effort? : String,
) -> @bridge.CallAnswer {
  @bridge.CallAnswer::new(Done, [
    ("threadId", Json::string(thread)),
    ("model", Json::string(model.unwrap_or("claude-sonnet-5-5"))),
    ("effort", Json::string(effort.unwrap_or("high"))),
  ])
}

///|
fn show(json : Json) -> String {
  json.stringify()
}

///|
fn launch_request_text() -> String {
  "{\"taskId\":\"TR1\",\"documentRefs\":[\"https://example.com/task\"],\"completionTarget\":\"draft_pr\",\"projectId\":\"project\"}"
}

///|
fn Rig::write_launch_file(self : Rig, text? : String) -> String {
  let path = "\{self.root}/launch.json"
  write_text(path, text.unwrap_or(launch_request_text()))
  path
}

///|
fn Rig::write_review_file(self : Rig, extra? : String) -> String {
  let path = "\{self.root}/review.json"
  write_text(
    path,
    "{\"taskId\":\"TR1\",\"workerAI\":\"Codex\",\"projectId\":\"project\",\"checkout\":\"\{self.checkout()}\",\"baseBranch\":\"base\",\"documentRefs\":[\"https://example.com/task\"],\"prUrl\":null\{extra.unwrap_or("")}}",
  )
  path
}

///|
fn Rig::launch_dir(self : Rig) -> String {
  self.state_dir("launch", "project\nTR1")
}

///|
fn Rig::review_dir(self : Rig) -> String {
  self.state_dir("review", "\{self.checkout()}\nw1")
}

///|
fn parse_arguments(command : String, argv : Array[String]) -> @args.Command {
  match
    (@args.parse_command(command, argv[:]) catch {
      _ => abort("bad arguments")
    }) {
    Run(parsed) => parsed
    Help => abort("help was asked for")
  }
}

///|
fn launch_args(
  request : String,
  extra~ : Array[String] = [],
) -> @workflow.LaunchInput {
  let argv = ["--request", request]
  argv.append(extra)
  match parse_arguments("launch", argv) {
    Launch(args) => args
    _ => abort("not a launch")
  }
}

///|
fn review_args(
  request : String,
  extra~ : Array[String] = [],
) -> @workflow.ReviewInput {
  let argv = ["--request", request]
  argv.append(extra)
  match parse_arguments("review", argv) {
    Review(args) => args
    _ => abort("not a review")
  }
}

///|
fn Rig::review_cloud(
  _ : Rig,
) -> async (@workflow.ReviewInput) -> Json raise @failure.TaskFailed {
  _ => @failure.fail("the cloud review was asked for")
}

///|
fn bridge_answer(value : Json) -> @bridge.CallAnswer {
  @bridge.CallAnswer::of_json(value).unwrap()
}
