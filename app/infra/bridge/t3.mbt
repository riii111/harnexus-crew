///|
/// `which` finds a program on PATH.
priv struct T3Deps {
  env : @environment.Env
  which : (String) -> String?
}

///|
/// Carries the harnexus App operations a task sends to T3 Code's t3 CLI, answering with the same outcomes.
async fn call_t3(
  deps : T3Deps,
  tool : String,
  args : Map[String, Json],
) -> CallAnswer noraise {
  match tool {
    "create_thread" => start_thread(deps, args)
    "send_message_to_thread" => send_message(deps, args)
    _ => unsupported("T3 Code does not offer \{tool}")
  }
}

///|
/// T3 Code creates the worktree before it answers, so a start waits longer than a send.
const START_TIMEOUT_MS : Int32 = 180000

///|
const SEND_TIMEOUT_MS : Int32 = 60000

///|
const SHOW_TIMEOUT_MS : Int32 = 30000

///|
const KILL_GRACE_MS : Int32 = 5000

///|
const BIN_VARIABLE : String = "HARNEXUS_T3_BIN"

///|
const NO_THINKING : String = "T3 Code's t3 CLI cannot set a thinking level; leave out --thinking, and set it in T3 Code instead"

///|
async fn start_thread(
  deps : T3Deps,
  args : Map[String, Json],
) -> CallAnswer noraise {
  if args.get("thinking") is Some(_) {
    return unsupported(NO_THINKING)
  }
  let target = object_of(args.get("target"))
  guard text_of(args, "prompt") is Some(prompt) &&
    text_of(args, "title") is Some(title) &&
    text_of(args, "model") is Some(model) &&
    text_of(target, "projectId") is Some(project) else {
    return not_sent("create_thread needs prompt, title, model and a project")
  }
  let argv = [
    "thread",
    "start",
    project,
    "-",
    "--title",
    title,
    "--provider",
    provider_of(model),
    "--model",
    model,
  ]
  if worktree_base(target) is Some(base) {
    argv.push("--worktree")
    argv.push(base)
  }
  argv.push("--json")
  let stdout = match run_t3(deps, argv, prompt, START_TIMEOUT_MS) {
    Ran(stdout) => stdout
    Refused(answer) => return answer
  }
  guard printed(stdout) is Some(started) &&
    started.get("threadId") is Some(String(thread_id)) else {
    return unknown(
      "t3 thread start answered without a thread: \{@text.excerpt(stdout)}",
    )
  }
  CallAnswer::new(Done, [
    ("threadId", Json::string(thread_id)),
    ("model", model_of(deps, thread_id)),
    ("effort", Json::null()),
  ])
}

///|
async fn send_message(
  deps : T3Deps,
  args : Map[String, Json],
) -> CallAnswer noraise {
  // A send cannot change the thread's settings, so a model or thinking for it is refused rather than dropped.
  if args.get("thinking") is Some(_) {
    return unsupported(NO_THINKING)
  }
  if args.get("model") is Some(_) {
    return unsupported(
      "T3 Code's t3 CLI cannot change a thread's model; leave out --model, and change it in T3 Code instead",
    )
  }
  guard text_of(args, "threadId") is Some(thread_id) &&
    text_of(args, "prompt") is Some(prompt) else {
    return not_sent("send_message_to_thread needs threadId and prompt")
  }
  match
    run_t3(
      deps,
      ["thread", "send", thread_id, "-", "--json"],
      prompt,
      SEND_TIMEOUT_MS,
    ) {
    Ran(_) => CallAnswer::new(Done, [("threadId", Json::string(thread_id))])
    Refused(answer) => answer
  }
}

///|
/// A Codex App worker starts from the project's checked-out branch, and T3 Code needs that base named.
const DEFAULT_WORKTREE_BASE : String = "HEAD"

///|
fn worktree_base(target : Map[String, Json]) -> String? {
  let environment = object_of(target.get("environment"))
  guard environment.get("type") is Some(String("worktree")) else { return None }
  let state = object_of(environment.get("startingState"))
  match state.get("branchName") {
    Some(String(branch)) => Some(branch)
    _ => Some(DEFAULT_WORKTREE_BASE)
  }
}

///|
/// The provider instances T3 Code creates for Claude Code and Codex.
fn provider_of(model : String) -> String {
  if model.has_prefix("claude-") {
    "claudeAgent"
  } else {
    "codex"
  }
}

///|
/// The model the thread runs on as T3 Code reports it, or null when it cannot tell.
async fn model_of(deps : T3Deps, thread_id : String) -> Json noraise {
  let argv = ["thread", "show", thread_id, "--messages", "0", "--json"]
  guard run_t3(deps, argv, "", SHOW_TIMEOUT_MS) is Ran(stdout) &&
    printed(stdout) is Some(shown) &&
    object_of(shown.get("thread")).get("model") is Some(String(_) as model) else {
    return Json::null()
  }
  model
}

///|
priv enum Ran {
  Ran(String)
  Refused(CallAnswer)
}

///|
async fn run_t3(
  deps : T3Deps,
  args : Array[String],
  input : String,
  timeout_ms : Int32,
) -> Ran noraise {
  let path = match binary(deps) {
    Ok(path) => path
    Err(message) => return Refused(not_sent(message))
  }
  let run = @process.run_process(
    path,
    args,
    input,
    cwd=deps.env.home(),
    env=deps.env.to_map(),
    timeout_ms~,
    kill_grace_ms=KILL_GRACE_MS,
  ) catch {
    @boundary.ProcessRunFailed(started~, message~) =>
      return Refused(
        if started {
          unknown("no answer: \{message}")
        } else {
          not_sent(
            "\{message}; install T3 Code, or set \{BIN_VARIABLE} to its t3 CLI",
          )
        },
      )
  }
  if !(run.ended is Exit) {
    return Refused(
      unknown(
        "no answer: t3 \{args[0]} \{args[1]} ended by \{run.ended.name()}",
      ),
    )
  }
  if run.status == 0 {
    return Ran(run.stdout)
  }
  let brief_stderr = @text.excerpt(run.stderr)
  let reason = if brief_stderr == "" {
    "t3 exited with \{run.status}"
  } else {
    brief_stderr
  }
  for rule in before_sending {
    let (patterns, hint) = rule
    if patterns.any(pattern => run.stderr.contains(pattern)) {
      return Refused(
        not_sent(
          match hint {
            Some(hint) => "\{reason}; \{hint}"
            None => reason
          },
        ),
      )
    }
  }
  Refused(unknown(reason))
}

///|
/// Failures the CLI reports before it reaches the server or that the server says left nothing behind; any other failure may come after the thread was made or the message queued.
let before_sending : Array[(Array[String], String?)] = [
  (["No running T3 Code server"], None),
  (
    ["No T3 Code project matches"],
    Some("add the folder to T3 Code as a project with `t3 project add <path>`"),
  ),
  (["No thread was created"], None),
  (
    ["Failed to reserve loopback port", "listen EPERM"],
    Some("run outside the sandbox"),
  ),
]

///|
fn binary(deps : T3Deps) -> Result[String, String] {
  match deps.env.get(BIN_VARIABLE) {
    Some(set) if set != "" =>
      if set.has_prefix("/") {
        Ok(set)
      } else {
        Err("\{BIN_VARIABLE} must be an absolute path")
      }
    // The desktop app writes its launcher here without putting it on PATH, so a t3 on PATH is preferred and this one is the fallback.
    _ =>
      Ok(
        match (deps.which)("t3") {
          Some(found) => found
          None => @path.join([deps.env.t3_home(), "bin/t3"])
        },
      )
  }
}

///|
/// The one JSON object a --json command prints, on its last line.
fn printed(stdout : String) -> Map[String, Json]? {
  let trimmed = @text.js_trim(stdout)
  let last = match trimmed.rev_find("\n") {
    Some(at) => trimmed[at + 1:].to_owned()
    None => trimmed
  }
  match (@jsonio.parse(last) catch { _ => Json::null() }) {
    Object(members) => Some(members)
    _ => None
  }
}

///|
fn object_of(value : Json?) -> Map[String, Json] {
  match value {
    Some(Object(members)) => members
    _ => Map([])
  }
}

///|
fn text_of(members : Map[String, Json], key : String) -> String? {
  match members.get(key) {
    Some(String(text)) => Some(text)
    _ => None
  }
}

///|
pub async fn call_t3_in(
  env : @environment.Env,
  tool : String,
  args : Map[String, Json],
  which~ : (String) -> String?,
) -> CallAnswer noraise {
  call_t3({ env, which, }, tool, args)
}
