///|
fn env_of(pairs : Array[(String, String)]) -> @environment.Env {
  let vars = Map([])
  for pair in pairs {
    let (name, value) = pair
    vars[name] = value
  }
  @environment.Env::new(vars, login_home="/login")
}

///|
/// A file system of a few paths: `/fx/doc.md` is a file, the others directories, and `/fx/link` is a symlink to the first worktree.
fn probe() -> FileProbe {
  let dirs = [
    "/fx", "/fx/wt", "/fx/wt/ab12", "/fx/wt/ab12/repo", "/fx/wt/ab12/other", "/fx/wt/loose",
    "/fx/outside",
  ]
  let resolved = fn(path : String) {
    let absolute = @path.resolve(cwd="/cwd", [path])
    if absolute == "/fx/link" {
      "/fx/wt/ab12/repo"
    } else {
      absolute
    }
  }
  {
    path_exists: path => {
      let real = resolved(path)
      dirs.contains(real) || real == "/fx/doc.md"
    },
    is_directory: path => dirs.contains(resolved(path)),
    real_path_or_self: path => resolved(path),
  }
}

///|
fn parsed(text : String) -> Json raise {
  @jsonio.parse(text)
}

///|
async fn launch(text : String) -> String {
  try {
    let request = LaunchRequest::from_json(parsed(text), probe())
    "ok " + @jsonio.stringify(request.to_json())
  } catch {
    @failure.TaskFailed(message) => "refused: " + message
    _ => "not JSON"
  }
}

///|
/// Answers each git query from a script keyed by its arguments and records every command line.
struct Script {
  answers : Map[String, String]
  seen : Array[Array[String]]
  envs : Array[Map[String, String]]
}

///|
fn Script::new(answers : Map[String, String]) -> Script {
  { answers, seen: [], envs: [], }
}

///|
fn Script::runner(self : Script) -> GitRunner {
  {
    run: (argv, env) => {
      self.seen.push(argv)
      self.envs.push(env)
      let tail = argv[9:].to_owned().join(" ")
      match self.answers.get(tail) {
        Some(out) => { status: 0, stdout: out + "\n", stderr: "", }
        None => { status: 128, stdout: "", stderr: "fatal: unknown \{tail}\n", }
      }
    },
  }
}

///|
const REVIEW : String = "{\"taskId\":\"T-1\",\"workerAI\":\"Codex\",\"projectId\":\"p\",\"checkout\":\"/fx/wt/ab12/repo\",\"baseBranch\":\"main\",\"documentRefs\":[\"https://example.com/t\"]}"

///|
async fn review(text : String, scope : ReviewScope, script : Script) -> String {
  try {
    let git = Git::new(script.runner(), env_of([("HOME", "/h")]))
    let request = ReviewRequest::from_json(parsed(text), scope, probe(), git)
    "ok " + @jsonio.stringify(request.to_json())
  } catch {
    @failure.TaskFailed(message) => "refused: " + message
    _ => "not JSON"
  }
}

///|
fn toplevel(checkout : String) -> Script {
  Script::new({ "rev-parse --show-toplevel": checkout })
}

///|
async test "a launch request keeps the members it was given, null included" {
  inspect(
    launch(
      "{\"taskId\":\"T-1\",\"documentRefs\":[\"/fx/doc.md\"],\"completionTarget\":\"draft_pr\",\"projectId\":\"p\",\"startingBranch\":null}",
    ),
    content="ok {\"taskId\":\"T-1\",\"documentRefs\":[\"/fx/doc.md\"],\"completionTarget\":\"draft_pr\",\"projectId\":\"p\",\"startingBranch\":null}",
  )
}

///|
async test "a launch request is refused on its first problem in member order" {
  let base = "\"documentRefs\":[\"/fx/doc.md\"],\"projectId\":\"p\""
  inspect(launch("[]"), content="refused: request must be a JSON object")
  inspect(
    launch(
      "{\"taskId\":\"T\",\"foo\":1,\"bar\":1,\"completionTarget\":\"merge\"," +
      base +
      "}",
    ),
    content="refused: unknown request fields: bar, foo",
  )
  inspect(
    launch("{\"taskId\":\"T\"}"),
    content="refused: missing request fields: completionTarget, documentRefs, projectId",
  )
  inspect(
    launch("{\"taskId\":\"bad id\",\"completionTarget\":\"nope\"," + base + "}"),
    content="refused: taskId must start with a letter, digit, _ or # and contain only letters, digits and _ . # / : -",
  )
  inspect(
    launch("{\"taskId\":\"T\",\"completionTarget\":\"nope\"," + base + "}"),
    content="refused: completionTarget must be implementation, draft_pr, or merge",
  )
}

///|
async test "a task ID takes letters and digits of any script and a few marks" {
  for id in ["T-1", "名前", "#12", "a/b:c.d", "٣"] {
    let text = "{\"taskId\":\"\{id}\",\"documentRefs\":[\"https://e.com/t\"],\"completionTarget\":\"merge\",\"projectId\":\"p\"}"
    inspect(launch(text).has_prefix("ok "), content="true")
  }
  for id in ["-a", "a b", "a\\nb", "", "a$"] {
    let text = "{\"taskId\":\"\{id}\",\"documentRefs\":[\"https://e.com/t\"],\"completionTarget\":\"merge\",\"projectId\":\"p\"}"
    inspect(launch(text).has_prefix("refused: "), content="true")
  }
}

///|
async test "a document reference is an HTTPS URL or an existing absolute path, once" {
  let rest = ",\"taskId\":\"T\",\"completionTarget\":\"merge\",\"projectId\":\"p\"}"
  inspect(
    launch("{\"documentRefs\":[\"/fx/missing\"]" + rest),
    content="refused: document reference must be an existing absolute path or HTTPS URL: /fx/missing",
  )
  inspect(
    launch("{\"documentRefs\":[\"docs/a.md\"]" + rest),
    content="refused: document reference must be an existing absolute path or HTTPS URL: docs/a.md",
  )
  inspect(
    launch("{\"documentRefs\":[\"https://e.com/a\",\"https://e.com/a\"]" + rest),
    content="refused: documentRefs must not contain duplicate references",
  )
  inspect(
    launch("{\"documentRefs\":[]" + rest),
    content="refused: documentRefs must be a nonempty list of paths or URLs",
  )
  inspect(
    launch("{\"documentRefs\":[\"https://\"]" + rest),
    content="refused: document reference must be an existing absolute path or HTTPS URL: https://",
  )
  inspect(
    launch("{\"documentRefs\":[\"HTTPS://E.com/a\"]" + rest).has_prefix("ok "),
    content="true",
  )
}

///|
async test "a starting branch is a name Git would take, or null" {
  let rest = ",\"taskId\":\"T\",\"documentRefs\":[\"https://e.com/t\"],\"completionTarget\":\"merge\",\"projectId\":\"p\"}"
  for branch in ["\"main\"", "\"feature/x-1.y\"", "null"] {
    inspect(
      launch("{\"startingBranch\":" + branch + rest).has_prefix("ok "),
      content="true",
    )
  }
  for
    branch in [
      "\"a..b\"", "\"x.lock\"", "\"x/\"", "\"x.\"", "\"-x\"", "\"a b\"", "5", "\"\"",
    ] {
    inspect(
      launch("{\"startingBranch\":" + branch + rest),
      content="refused: startingBranch must be a branch name",
    )
  }
}

///|
async test "a review request is confirmed as the top level of an app worktree" {
  let scope = Worktrees("/fx/wt")
  inspect(
    review(REVIEW, scope, toplevel("/fx/wt/ab12/repo")),
    content="ok {\"taskId\":\"T-1\",\"workerAI\":\"Codex\",\"checkout\":\"/fx/wt/ab12/repo\",\"baseBranch\":\"main\",\"documentRefs\":[\"https://example.com/t\"],\"prUrl\":null,\"projectId\":\"p\"}",
  )
  inspect(
    review(REVIEW, scope, toplevel("/fx/wt/ab12")),
    content="refused: checkout must be the top level of a worker worktree /fx/wt/<id>/<name>",
  )
  let outside = REVIEW.replace_all(old="/fx/wt/ab12/repo", new="/fx/outside")
  inspect(
    review(outside, scope, toplevel("/fx/outside")),
    content="refused: checkout must be the top level of a worker worktree /fx/wt/<id>/<name>",
  )
  inspect(
    review(outside, Cloud, toplevel("/fx/outside")).has_prefix("ok "),
    content="true",
  )
  let relative = REVIEW.replace_all(old="/fx/wt/ab12/repo", new="wt/ab12/repo")
  inspect(
    review(relative, Cloud, toplevel("/fx/outside")),
    content="refused: checkout must be the absolute path of a repository's top level",
  )
}

///|
async test "the checkout is saved as its real path" {
  let linked = REVIEW.replace_all(old="/fx/wt/ab12/repo", new="/fx/link")
  inspect(
    review(linked, Worktrees("/fx/wt"), toplevel("/fx/wt/ab12/repo")).has_prefix(
      "ok {\"taskId\":\"T-1\",\"workerAI\":\"Codex\",\"checkout\":\"/fx/wt/ab12/repo\"",
    ),
    content="true",
  )
}

///|
async test "in Cloud the project may be left out but not null" {
  let without = REVIEW.replace_all(old="\"projectId\":\"p\",", new="")
  inspect(
    review(without, Cloud, toplevel("/fx/wt/ab12/repo")).contains("projectId"),
    content="false",
  )
  inspect(
    review(without, Worktrees("/fx/wt"), toplevel("/fx/wt/ab12/repo")),
    content="refused: missing request fields: projectId",
  )
  let null_project = REVIEW.replace_all(
    old="\"projectId\":\"p\"",
    new="\"projectId\":null",
  )
  inspect(
    review(null_project, Cloud, toplevel("/fx/wt/ab12/repo")),
    content="refused: projectId must be a nonempty single-line string",
  )
}

///|
async test "a pull request URL is any host's pull request or null" {
  let top = toplevel("/fx/wt/ab12/repo")
  for url in ["https://github.com/o/r/pull/12", "https://h.example/a/b/pull/1/"] {
    let text = REVIEW.replace_all(old="}", new=",\"prUrl\":\"\{url}\"}")
    inspect(
      review(text, Worktrees("/fx/wt"), top).contains(url),
      content="true",
    )
  }
  for
    url in [
      "https://github.com/o/r/pull/0", "https://github.com/o/r/pull/012", "https://github.com/o/r/pulls/1",
      "http://github.com/o/r/pull/1", "https://github.com/o/pull/1", "https://git hub.com/o/r/pull/1",
    ] {
    let text = REVIEW.replace_all(old="}", new=",\"prUrl\":\"\{url}\"}")
    inspect(
      review(text, Worktrees("/fx/wt"), top),
      content="refused: prUrl must be a pull request URL or null",
    )
  }
}

///|
async test "the worker's chat ID is kept as given for the command to compare" {
  let text = REVIEW.replace_all(old="}", new=",\"workerChatId\":7}")
  let result = review(text, Worktrees("/fx/wt"), toplevel("/fx/wt/ab12/repo"))
  inspect(result.contains("\"workerChatId\":7"), content="true")
}

///|
async fn candidate_of(
  script : Script,
  previous : Map[String, Json]?,
  update_base : Bool,
) -> String {
  try {
    let git = Git::new(script.runner(), env_of([("HOME", "/h")]))
    let request = ReviewRequest::from_json(
      parsed(REVIEW),
      Worktrees("/fx/wt"),
      probe(),
      git,
    )
    let found = request.candidate(previous, update_base, git)
    "ok base=\{found.base} head=\{found.head}"
  } catch {
    @failure.TaskFailed(message) => "refused: " + message
    _ => "not JSON"
  }
}

///|
fn candidate_script(extra : Map[String, String]) -> Script {
  let answers = {
    "rev-parse --show-toplevel": "/fx/wt/ab12/repo",
    "rev-parse HEAD": "h1",
    "rev-parse --symbolic-full-name --verify --end-of-options main": "refs/heads/main",
    "rev-parse --verify refs/heads/main^{commit}": "b1",
    "merge-base b1 h1": "b1",
  }
  for key, value in extra {
    answers[key] = value
  }
  Script::new(answers)
}

///|
async test "a new review resolves its base from the branch" {
  let script = candidate_script({})
  inspect(candidate_of(script, None, false), content="ok base=b1 head=h1")
  inspect(script.seen.length(), content="5")
}

///|
async test "git runs without helpers or transports, in the checkout, and fetches nothing" {
  let script = candidate_script({})
  let _ = candidate_of(script, None, false)
  let argv = script.seen[0]
  inspect(
    argv.join(" "),
    content="git -c core.fsmonitor=false -c core.hooksPath=/dev/null -c protocol.allow=never -C /fx/wt/ab12/repo rev-parse --show-toplevel",
  )
  inspect(script.envs[0].get("GIT_NO_LAZY_FETCH").unwrap(), content="1")
  inspect(script.envs[0].get("HOME").unwrap(), content="/h")
}

///|
async test "a recorded base is kept until it is updated explicitly" {
  let recorded : Map[String, Json] = {
    "baseBranch": Json::string("main"),
    "base": Json::string("old"),
  }
  let script = candidate_script({ "merge-base old h1": "old" })
  inspect(
    candidate_of(script, Some(recorded), false),
    content="ok base=old head=h1",
  )
  inspect(
    candidate_of(candidate_script({}), Some(recorded), true),
    content="ok base=b1 head=h1",
  )
}

///|
async test "a recorded candidate must agree with the request" {
  let moved : Map[String, Json] = {
    "baseBranch": Json::string("develop"),
    "base": Json::string("old"),
  }
  inspect(
    candidate_of(candidate_script({}), Some(moved), false),
    content="refused: baseBranch changed; use --update-base after integrating upstream",
  )
  let unbased : Map[String, Json] = { "baseBranch": Json::string("main") }
  inspect(
    candidate_of(candidate_script({}), Some(unbased), false),
    content="refused: the recorded review candidate has no base",
  )
  let unnamed : Map[String, Json] = { "base": Json::string("old") }
  inspect(
    candidate_of(
      candidate_script({ "merge-base old h1": "old" }),
      Some(unnamed),
      false,
    ),
    content="ok base=old head=h1",
  )
}

///|
async test "a base that is not a branch or not an ancestor is refused" {
  inspect(
    candidate_of(
      candidate_script({
        "rev-parse --symbolic-full-name --verify --end-of-options main": "refs/tags/main",
      }),
      None,
      false,
    ),
    content="refused: baseBranch must name a local or remote branch",
  )
  inspect(
    candidate_of(candidate_script({ "merge-base b1 h1": "other" }), None, false),
    content="refused: review base must be an ancestor of head",
  )
  inspect(
    candidate_of(
      candidate_script({
        "rev-parse --symbolic-full-name --verify --end-of-options main": "refs/remotes/origin/main",
        "rev-parse --verify refs/remotes/origin/main^{commit}": "b1",
      }),
      None,
      false,
    ),
    content="ok base=b1 head=h1",
  )
}

///|
async test "a git failure is reported with its message and the no-fetch reminder" {
  inspect(
    candidate_of(
      Script::new({ "rev-parse --show-toplevel": "/fx/wt/ab12/repo" }),
      None,
      false,
    ),
    content="refused: fatal: unknown rev-parse HEAD; harnexus-crew never fetches, so fetch any missing commit in the worktree",
  )
}

///|
async test "the saved candidate holds the request and its commits" {
  let git = Git::new(candidate_script({}).runner(), env_of([]))
  let request = ReviewRequest::from_json(
    parsed(REVIEW),
    Worktrees("/fx/wt"),
    probe(),
    git,
  )
  let found = request.with_worker_chat_id("w-1").candidate(None, false, git)
  inspect(
    @jsonio.stringify(found.to_json()),
    content="{\"taskId\":\"T-1\",\"workerAI\":\"Codex\",\"checkout\":\"/fx/wt/ab12/repo\",\"baseBranch\":\"main\",\"documentRefs\":[\"https://example.com/t\"],\"prUrl\":null,\"projectId\":\"p\",\"workerChatId\":\"w-1\",\"head\":\"h1\",\"base\":\"b1\"}",
  )
}

///|
async test "template fields come from the request and are checked again" {
  let git = Git::new(candidate_script({}).runner(), env_of([]))
  let request = ReviewRequest::from_json(
    parsed(REVIEW),
    Worktrees("/fx/wt"),
    probe(),
    git,
  )
  let found = request.with_worker_chat_id("w-1").candidate(None, false, git)
  let fields = found.reviewer_fields("Cloud", probe())
  let names = []
  for name, value in fields {
    names.push("\{name}=\{value}")
  }
  inspect(
    names.join("|"),
    content="task_id=T-1|document_refs=- https://example.com/t|worker_ai=Codex|reply_to=Cloud|worker_chat_id=w-1|checkout=/fx/wt/ab12/repo|pr_url=null|base=b1|head=h1",
  )
  let launched = LaunchRequest::from_json(
    parsed(
      "{\"taskId\":\"T\",\"documentRefs\":[\"/fx/doc.md\"],\"completionTarget\":\"merge\",\"projectId\":\"p\"}",
    ),
    probe(),
  )
  let worker = launched.worker_fields(probe())
  inspect(worker["document_refs"], content="- /fx/doc.md")
  let gone : FileProbe = { ..probe(), path_exists: _ => false, }
  let refused = try {
    launched.worker_fields(gone) |> ignore
    "accepted"
  } catch {
    @failure.TaskFailed(message) => message
  }
  inspect(
    refused,
    content="document reference must be an existing absolute path or HTTPS URL: /fx/doc.md",
  )
}

///|
test "the sample fields are what a check fills the templates with" {
  inspect(sample_worker_fields()["completion_target"], content="draft_pr")
  inspect(sample_reviewer_fields("T3")["reply_to"], content="T3")
  inspect(sample_reviewer_fields("T3")["pr_url"], content="null")
}

///|
async test "a saved session is named by project and task, or by checkout and worker chat" {
  let launched = LaunchRequest::from_json(
    parsed(
      "{\"taskId\":\"T\",\"documentRefs\":[\"https://e.com/t\"],\"completionTarget\":\"merge\",\"projectId\":\"p\"}",
    ),
    probe(),
  )
  inspect(launched.session_key(), content="p\nT")
  let lone = LaunchRequest::from_json(
    parsed(
      "{\"taskId\":\"T\",\"documentRefs\":[\"https://e.com/t\"],\"completionTarget\":\"merge\",\"projectId\":\"\\ud800x\"}",
    ),
    probe(),
  )
  inspect(lone.session_key(), content="\u{FFFD}x\nT")
  let git = Git::new(candidate_script({}).runner(), env_of([]))
  let reviewed = ReviewRequest::from_json(
    parsed(REVIEW),
    Worktrees("/fx/wt"),
    probe(),
    git,
  )
  inspect(reviewed.session_key("w-1"), content="/fx/wt/ab12/repo\nw-1")
  inspect(
    reviewed.session_key("w\u{FFFD}"),
    content="/fx/wt/ab12/repo\nw\u{FFFD}",
  )
}

///|
test "a chat ID is one confirmed token" {
  inspect(chat_id("019a-b", "threadId"), content="019a-b")
  for bad in ["", "a b", "client-new-thread:1", "a\nb", " "] {
    let refused = try {
      chat_id(bad, "threadId") |> ignore
      "accepted"
    } catch {
      @failure.TaskFailed(message) => message
    }
    inspect(refused.has_prefix("threadId must be "), content="true")
  }
}

///|
test "the caller is the thread of the app the command runs in" {
  inspect(caller_id(env_of([("CODEX_THREAD_ID", "c-1")])), content="c-1")
  inspect(
    caller_id(env_of([("CODEX_THREAD_ID", "c-1"), ("T3CODE_THREAD_ID", "t-1")])),
    content="t-1",
  )
  let missing = try {
    caller_id(env_of([("T3CODE_THREAD_ID", "")])) |> ignore
    "accepted"
  } catch {
    @failure.TaskFailed(message) => message
  }
  inspect(
    missing,
    content="CODEX_THREAD_ID is not set; run harnexus-crew from a thread",
  )
  let spaced = try {
    caller_id(env_of([("CODEX_THREAD_ID", "a b")])) |> ignore
    "accepted"
  } catch {
    @failure.TaskFailed(message) => message
  }
  inspect(
    spaced,
    content="CODEX_THREAD_ID must be a confirmed chat ID without whitespace",
  )
}
