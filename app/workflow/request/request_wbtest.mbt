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
    resolve_real_path_or_self: path => resolved(path),
  }
}

///|
fn parse_json(text : String) -> Json raise {
  @jsonio.parse(text)
}

///|
async fn launch(text : String) -> String {
  try {
    let request = LaunchRequest::from_json(parse_json(text), probe())
    "ok " + request.to_json().stringify()
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
}

///|
fn Script::new(answers : Map[String, String]) -> Script {
  { answers, seen: [], }
}

///|
fn Script::runner(self : Script) -> @git.GitRunner {
  {
    run: (argv, _) => {
      self.seen.push(argv)
      let tail = query_of(argv)
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
    let git = @git.Git::new(script.runner(), @testkit.env_of([("HOME", "/h")]))
    let request = ReviewRequest::from_json(
      parse_json(text),
      scope,
      probe(),
      git,
    )
    "ok " + Json::object(request.members()).stringify()
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
async fn run_candidate(
  script : Script,
  previous : Map[String, Json]?,
  update_base : Bool,
) -> String {
  try {
    let git = @git.Git::new(script.runner(), @testkit.env_of([("HOME", "/h")]))
    let request = ReviewRequest::from_json(
      parse_json(REVIEW),
      Worktrees("/fx/wt"),
      probe(),
      git,
    )
    let found = request.resolve_candidate(previous, update_base, git)
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
async test "a launch request keeps the members it was given, null included" {
  inspect(
    launch(
      "{\"taskId\":\"T-1\",\"documentRefs\":[\"/fx/doc.md\"],\"completionTarget\":\"draft_pr\",\"projectId\":\"p\",\"startingBranch\":null}",
    ),
    content="ok {\"taskId\":\"T-1\",\"documentRefs\":[\"/fx/doc.md\"],\"completionTarget\":\"draft_pr\",\"projectId\":\"p\",\"startingBranch\":null}",
  )
}

///|
async test "a launch request that is not a JSON object is refused" {
  inspect(launch("[]"), content="refused: request must be a JSON object")
}

///|
async test "a launch request with unknown members is refused, naming them in order" {
  inspect(
    launch(
      "{\"taskId\":\"T\",\"foo\":1,\"bar\":1,\"documentRefs\":[\"https://e.com/t\"],\"completionTarget\":\"merge\",\"projectId\":\"p\"}",
    ),
    content="refused: unknown request fields: bar, foo",
  )
}

///|
async test "a launch request without required members is refused, naming them in order" {
  inspect(
    launch("{\"taskId\":\"T\"}"),
    content="refused: missing request fields: completionTarget, documentRefs, projectId",
  )
}

///|
async test "a launch request with several invalid members is refused on the first in member order" {
  inspect(
    launch(
      "{\"taskId\":\"bad id\",\"completionTarget\":\"nope\",\"documentRefs\":[\"https://e.com/t\"],\"projectId\":\"p\"}",
    ),
    content="refused: taskId must start with a letter, digit, _ or # and contain only letters, digits and _ . # / : -",
  )
}

///|
async test "a launch request with an unknown completion target is refused" {
  inspect(
    launch(
      "{\"taskId\":\"T\",\"completionTarget\":\"nope\",\"documentRefs\":[\"https://e.com/t\"],\"projectId\":\"p\"}",
    ),
    content="refused: completionTarget must be implementation, draft_pr, or merge",
  )
}

///|
async test "a task ID takes ASCII letters and digits and a few marks" {
  for id in ["T-1", "#12", "a/b:c.d"] {
    let text = launch_text(task_id=id)
    assert_eq(launch(text), "ok " + text, msg=id)
  }
}

///|
async test "a task ID that starts with another mark or holds other characters is refused" {
  for id in ["-a", "a b", "a$", "名前", "٣"] {
    assert_eq(
      launch(launch_text(task_id=id)),
      "refused: taskId must start with a letter, digit, _ or # and contain only letters, digits and _ . # / : -",
      msg=id,
    )
  }
}

///|
async test "a blank task ID or one with a line break is refused as not a single line" {
  for id in ["", "a\\nb"] {
    assert_eq(
      launch(launch_text(task_id=id)),
      "refused: taskId must be a nonempty single-line string",
      msg=id,
    )
  }
}

///|
async test "a document reference that is an HTTPS URL or an existing absolute path is accepted" {
  for reference in ["https://e.com/a", "HTTPS://E.com/a", "/fx/doc.md"] {
    let text = launch_text(refs="\"\{reference}\"")
    assert_eq(launch(text), "ok " + text, msg=reference)
  }
}

///|
async test "a document reference that is a missing path, a relative path or a URL without a host is refused" {
  for reference in ["/fx/missing", "docs/a.md", "https://"] {
    assert_eq(
      launch(launch_text(refs="\"\{reference}\"")),
      "refused: document reference must be an existing absolute path or HTTPS URL: \{reference}",
      msg=reference,
    )
  }
}

///|
async test "a document reference listed twice is refused" {
  inspect(
    launch(launch_text(refs="\"https://e.com/a\",\"https://e.com/a\"")),
    content="refused: documentRefs must not contain duplicate references",
  )
}

///|
async test "an empty list of document references is refused" {
  inspect(
    launch(launch_text(refs="")),
    content="refused: documentRefs must be a nonempty list of paths or URLs",
  )
}

///|
async test "a starting branch that is a name Git would take, or null, is kept as given" {
  for branch in ["\"main\"", "\"feature/x-1.y\"", "null"] {
    let text = launch_text(branch~)
    assert_eq(launch(text), "ok " + text, msg=branch)
  }
}

///|
async test "a starting branch that is not a name Git would take is refused" {
  for
    branch in [
      "\"a..b\"", "\"x.lock\"", "\"x/\"", "\"x.\"", "\"-x\"", "\"a b\"", "5", "\"\"",
    ] {
    assert_eq(
      launch(launch_text(branch~)),
      "refused: startingBranch must be a branch name",
      msg=branch,
    )
  }
}

///|
async test "a review request whose checkout is the top level of an app worktree is accepted" {
  assert_eq(
    review(REVIEW, Worktrees("/fx/wt"), toplevel("/fx/wt/ab12/repo")),
    accepted_review(),
  )
}

///|
async test "a review request is refused when its checkout is not the top level of its repository" {
  inspect(
    review(REVIEW, Worktrees("/fx/wt"), toplevel("/fx/wt/ab12")),
    content="refused: checkout must be the top level of a worker worktree /fx/wt/<id>/<name>",
  )
}

///|
async test "a checkout outside the app worktrees is refused for an app and accepted in Cloud" {
  let outside = REVIEW.replace_all(old="/fx/wt/ab12/repo", new="/fx/outside")
  let top = toplevel("/fx/outside")

  inspect(
    review(outside, Worktrees("/fx/wt"), top),
    content="refused: checkout must be the top level of a worker worktree /fx/wt/<id>/<name>",
  )
  assert_eq(
    review(outside, Cloud, top),
    accepted_review(checkout="/fx/outside"),
  )
}

///|
async test "a relative checkout is refused in Cloud" {
  let relative = REVIEW.replace_all(old="/fx/wt/ab12/repo", new="wt/ab12/repo")
  inspect(
    review(relative, Cloud, toplevel("/fx/outside")),
    content="refused: checkout must be the absolute path of a repository's top level",
  )
}

///|
async test "the checkout is saved as its real path" {
  let linked = REVIEW.replace_all(old="/fx/wt/ab12/repo", new="/fx/link")
  assert_eq(
    review(linked, Worktrees("/fx/wt"), toplevel("/fx/wt/ab12/repo")),
    accepted_review(),
  )
}

///|
async test "in Cloud a review request may leave out the project" {
  let without = REVIEW.replace_all(old="\"projectId\":\"p\",", new="")
  assert_eq(
    review(without, Cloud, toplevel("/fx/wt/ab12/repo")),
    accepted_review(project=""),
  )
}

///|
async test "a review request that leaves out the project is refused outside Cloud" {
  let without = REVIEW.replace_all(old="\"projectId\":\"p\",", new="")
  inspect(
    review(without, Worktrees("/fx/wt"), toplevel("/fx/wt/ab12/repo")),
    content="refused: missing request fields: projectId",
  )
}

///|
async test "a null project is refused even in Cloud" {
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
async test "a pull request URL of any host, or null, is kept as given" {
  for
    literal in [
      "\"https://github.com/o/r/pull/12\"", "\"https://h.example/a/b/pull/1/\"",
      "null",
    ] {
    let text = REVIEW.replace_all(old="}", new=",\"prUrl\":\{literal}}")
    assert_eq(
      review(text, Worktrees("/fx/wt"), toplevel("/fx/wt/ab12/repo")),
      accepted_review(pr_url=literal),
      msg=literal,
    )
  }
}

///|
async test "a URL that is not an HTTPS pull request is refused" {
  for
    url in [
      "https://github.com/o/r/pull/0", "https://github.com/o/r/pull/012", "https://github.com/o/r/pulls/1",
      "http://github.com/o/r/pull/1", "https://github.com/o/pull/1", "https://git hub.com/o/r/pull/1",
    ] {
    let text = REVIEW.replace_all(old="}", new=",\"prUrl\":\"\{url}\"}")
    assert_eq(
      review(text, Worktrees("/fx/wt"), toplevel("/fx/wt/ab12/repo")),
      "refused: prUrl must be a pull request URL or null",
      msg=url,
    )
  }
}

///|
async test "a worker chat ID given as a string is kept" {
  assert_eq(
    review(
      with_worker_chat("\"w-1\""),
      Worktrees("/fx/wt"),
      toplevel("/fx/wt/ab12/repo"),
    ),
    accepted_review(tail=",\"workerChatId\":\"w-1\""),
  )
}

///|
async test "a null worker chat ID reads as none" {
  assert_eq(
    review(
      with_worker_chat("null"),
      Worktrees("/fx/wt"),
      toplevel("/fx/wt/ab12/repo"),
    ),
    accepted_review(),
  )
}

///|
async test "a worker chat ID that is neither a string nor null is refused" {
  for value in ["7", "true", "[\"w\"]", "{}"] {
    assert_eq(
      review(
        with_worker_chat(value),
        Worktrees("/fx/wt"),
        toplevel("/fx/wt/ab12/repo"),
      ),
      "refused: workerChatId must be a string or null",
      msg=value,
    )
  }
}

///|
async test "a new review resolves its base from the branch" {
  let script = candidate_script({})

  inspect(run_candidate(script, None, false), content="ok base=b1 head=h1")
  assert_eq(script.queries(), [
    "rev-parse --show-toplevel", "rev-parse HEAD", "rev-parse --symbolic-full-name --verify --end-of-options main",
    "rev-parse --verify refs/heads/main^{commit}", "merge-base b1 h1",
  ])
}

///|
async test "a recorded base is kept until it is updated explicitly" {
  let recorded : Map[String, Json] = {
    "baseBranch": Json::string("main"),
    "base": Json::string("old"),
  }
  let script = candidate_script({ "merge-base old h1": "old" })
  inspect(
    run_candidate(script, Some(recorded), false),
    content="ok base=old head=h1",
  )
  inspect(
    run_candidate(candidate_script({}), Some(recorded), true),
    content="ok base=b1 head=h1",
  )
}

///|
async test "a recorded candidate for another base branch is refused" {
  let moved : Map[String, Json] = {
    "baseBranch": Json::string("develop"),
    "base": Json::string("old"),
  }
  inspect(
    run_candidate(candidate_script({}), Some(moved), false),
    content="refused: baseBranch changed; use --update-base after integrating upstream",
  )
}

///|
async test "a recorded candidate without a base is refused" {
  let unbased : Map[String, Json] = { "baseBranch": Json::string("main") }
  inspect(
    run_candidate(candidate_script({}), Some(unbased), false),
    content="refused: the recorded review candidate has no base",
  )
}

///|
async test "a recorded candidate without a base branch keeps its base" {
  let unnamed : Map[String, Json] = { "base": Json::string("old") }
  inspect(
    run_candidate(
      candidate_script({ "merge-base old h1": "old" }),
      Some(unnamed),
      false,
    ),
    content="ok base=old head=h1",
  )
}

///|
async test "a base that is not a branch is refused" {
  inspect(
    run_candidate(
      candidate_script({
        "rev-parse --symbolic-full-name --verify --end-of-options main": "refs/tags/main",
      }),
      None,
      false,
    ),
    content="refused: baseBranch must name a local or remote branch",
  )
}

///|
async test "a base that is not an ancestor of head is refused" {
  inspect(
    run_candidate(
      candidate_script({ "merge-base b1 h1": "other" }),
      None,
      false,
    ),
    content="refused: review base must be an ancestor of head",
  )
}

///|
async test "a base on a remote branch is accepted" {
  inspect(
    run_candidate(
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
async test "a failing git query refuses the review with the message git gave" {
  inspect(
    run_candidate(
      Script::new({ "rev-parse --show-toplevel": "/fx/wt/ab12/repo" }),
      None,
      false,
    ),
    content="refused: fatal: unknown rev-parse HEAD; harnexus-crew never fetches, so fetch any missing commit in the worktree",
  )
}

///|
async test "the saved candidate holds the request and its commits" {
  let found = resolved_candidate()
  inspect(
    found.to_json().stringify(),
    content="{\"taskId\":\"T-1\",\"workerAI\":\"Codex\",\"checkout\":\"/fx/wt/ab12/repo\",\"baseBranch\":\"main\",\"documentRefs\":[\"https://example.com/t\"],\"prUrl\":null,\"projectId\":\"p\",\"workerChatId\":\"w-1\",\"head\":\"h1\",\"base\":\"b1\"}",
  )
}

///|
async test "reviewer template fields come from the review candidate" {
  let found = resolved_candidate()
  inspect(
    fields_text(found.build_reviewer_fields("Cloud", probe())),
    content="task_id=T-1|document_refs=- https://example.com/t|worker_ai=Codex|reply_to=Cloud|worker_chat_id=w-1|checkout=/fx/wt/ab12/repo|pr_url=null|base=b1|head=h1",
  )
}

///|
async test "worker template fields come from the launch request" {
  let request = parsed_launch(launch_text(refs="\"/fx/doc.md\""))
  inspect(
    fields_text(request.build_worker_fields(probe())),
    content="task_id=T|document_refs=- /fx/doc.md|completion_target=merge",
  )
}

///|
async test "template fields are refused when a document reference has gone since the request was read" {
  let request = parsed_launch(launch_text(refs="\"/fx/doc.md\""))
  let gone : FileProbe = { ..probe(), path_exists: _ => false, }
  assert_eq(
    @testkit.failure_of(() => ignore(request.build_worker_fields(gone))),
    "document reference must be an existing absolute path or HTTPS URL: /fx/doc.md",
  )
}

///|
async test "the sample worker fields have the fields a launch gives" {
  let request = parsed_launch(launch_text())
  assert_eq(
    field_names(sample_worker_fields()),
    field_names(request.build_worker_fields(probe())),
  )
}

///|
async test "the sample reviewer fields have the fields a review gives" {
  let found = resolved_candidate()
  assert_eq(
    field_names(sample_reviewer_fields("T3")),
    field_names(found.build_reviewer_fields("T3", probe())),
  )
}

///|
test "the sample reviewer fields are addressed to the reply target given" {
  inspect(sample_reviewer_fields("T3")["reply_to"], content="T3")
}

///|
async test "a launch request names its session by project and task" {
  for entry in [("p", "p\nT"), ("\\ud800x", "\u{FFFD}x\nT")] {
    let (project, key) = entry
    let request = parsed_launch(launch_text(project~))
    assert_eq(request.session_key(), key, msg=project)
  }
}

///|
async test "a review request names its session by checkout and worker chat" {
  let reviewed = parsed_review()
  for chat in ["w-1", "w\u{FFFD}"] {
    assert_eq(reviewed.session_key(chat), "/fx/wt/ab12/repo\n\{chat}", msg=chat)
  }
}

///|
test "a confirmed chat ID is accepted as it is" {
  inspect(check_chat_id("019a-b", "threadId"), content="019a-b")
}

///|
async test "a chat ID with whitespace or a pending-thread prefix is refused as unconfirmed" {
  for bad in ["a b", "client-new-thread:1"] {
    assert_eq(
      @testkit.failure_of(() => ignore(check_chat_id(bad, "threadId"))),
      "threadId must be a confirmed chat ID without whitespace",
      msg=bad,
    )
  }
}

///|
async test "a blank chat ID or one with a line break is refused as not a single line" {
  for bad in ["", " ", "a\nb"] {
    assert_eq(
      @testkit.failure_of(() => ignore(check_chat_id(bad, "threadId"))),
      "threadId must be a nonempty single-line string",
      msg=bad,
    )
  }
}

///|
test "the caller is the thread of the app the command runs in" {
  let cases = [
    ("Codex", [("CODEX_THREAD_ID", "c-1")], "c-1"),
    (
      "T3 Code",
      [("CODEX_THREAD_ID", "c-1"), ("T3CODE_THREAD_ID", "t-1")],
      "t-1",
    ),
  ]
  for entry in cases {
    let (app, vars, thread) = entry
    assert_eq(read_caller_id(@testkit.env_of(vars)), thread, msg=app)
  }
}

///|
async test "a caller without a thread variable is refused with the variable to set" {
  assert_eq(
    @testkit.failure_of(() => {
      ignore(read_caller_id(@testkit.env_of([("T3CODE_THREAD_ID", "")])))
    }),
    "CODEX_THREAD_ID is not set; run harnexus-crew from a thread",
  )
}

///|
async test "a thread variable with whitespace is refused as unconfirmed" {
  assert_eq(
    @testkit.failure_of(() => {
      ignore(read_caller_id(@testkit.env_of([("CODEX_THREAD_ID", "a b")])))
    }),
    "CODEX_THREAD_ID must be a confirmed chat ID without whitespace",
  )
}

///|
fn query_of(argv : Array[String]) -> String {
  argv[9:].to_owned().join(" ")
}

///|
fn Script::queries(self : Script) -> Array[String] {
  self.seen.map(query_of)
}

///|
fn launch_text(
  task_id~ : String = "T",
  refs~ : String = "\"https://e.com/t\"",
  project~ : String = "p",
  branch? : String,
) -> String {
  let starting = match branch {
    Some(literal) => ",\"startingBranch\":\{literal}"
    None => ""
  }
  "{\"taskId\":\"\{task_id}\",\"documentRefs\":[\{refs}],\"completionTarget\":\"merge\",\"projectId\":\"\{project}\"\{starting}}"
}

///|
fn accepted_review(
  checkout~ : String = "/fx/wt/ab12/repo",
  pr_url~ : String = "null",
  project~ : String = ",\"projectId\":\"p\"",
  tail~ : String = "",
) -> String {
  "ok {\"taskId\":\"T-1\",\"workerAI\":\"Codex\",\"checkout\":\"\{checkout}\",\"baseBranch\":\"main\",\"documentRefs\":[\"https://example.com/t\"],\"prUrl\":\{pr_url}\{project}\{tail}}"
}

///|
fn with_worker_chat(value : String) -> String {
  REVIEW.replace_all(old="}", new=",\"workerChatId\":\{value}}")
}

///|
async fn parsed_launch(text : String) -> LaunchRequest {
  LaunchRequest::from_json(parse_json(text), probe())
}

///|
async fn parsed_review() -> ReviewRequest {
  let git = @git.Git::new(candidate_script({}).runner(), @testkit.env_of([]))
  ReviewRequest::from_json(
    parse_json(REVIEW),
    Worktrees("/fx/wt"),
    probe(),
    git,
  )
}

///|
async fn resolved_candidate() -> ReviewCandidate {
  let git = @git.Git::new(candidate_script({}).runner(), @testkit.env_of([]))
  parsed_review().with_worker_chat_id("w-1").resolve_candidate(None, false, git)
}

///|
fn field_names(fields : Map[String, String]) -> Array[String] {
  let names = []
  for name, _ in fields {
    names.push(name)
  }
  names
}

///|
fn fields_text(fields : Map[String, String]) -> String {
  let entries = []
  for name, value in fields {
    entries.push("\{name}=\{value}")
  }
  entries.join("|")
}
