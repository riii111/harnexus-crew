///|
/// Reviews in a Claude Code cloud session with a Codex CLI run beside the worker, answering with its result instead of a chat in the app.
/// With `ask`, passes that message to the same reviewer instead.
pub async fn review(
  args : @args.ReviewArgs,
  env : @environment.Env,
) -> Json raise @failure.TaskFailed {
  review_in(Context::of_env(env), args)
}

///|
async fn review_in(
  ctx : Context,
  args : @args.ReviewArgs,
) -> Json raise @failure.TaskFailed {
  let request = read_request(ctx, args.request)
  let request = match request.worker_chat_id {
    None =>
      request.with_worker_chat_id(
        ctx.env.get_nonempty("CLAUDE_CODE_SESSION_ID").unwrap_or("cloud"),
      )
    Some(_) => request
  }
  // One reviewer per task and checkout, as in the app.
  let directory = @store.state_directory(
    ctx.env.state_root(),
    "cloud-review",
    @jsonio.lossy_text("\{request.checkout}\u{0}\{request.task_id}"),
  )
  @store.prepare_directory(directory) catch {
    failed => @failure.fail(failed.user_message())
  }
  let lock = "\{directory}/lock.json"
  let token = @store.acquire(lock, "review")
  defer @store.release(lock, token)
  match args.ask {
    None => reviewed(ctx, args, directory, request)
    Some(ask) => asked(ctx, ask, directory, request)
  }
}

///|
/// What one run works with.
/// A test replaces the parts that reach Git, the templates and the state files.
priv struct Context {
  env : @environment.Env
  probe : @request.FileProbe
  git : @request.Git
  prompt : (Map[String, String]) -> String raise @failure.TaskFailed
  save : (String, Json) -> Unit raise @failure.TaskFailed
}

///|
fn Context::of_env(env : @environment.Env) -> Context {
  {
    env,
    probe: {
      path_exists: path => @store.path_exists(path),
      is_directory: path => @store.is_directory(path),
      real_path_or_self: path => @store.real_path_or_self(path),
    },
    git: @request.Git::new(
      { run: (argv, vars) => @process.run_command(argv[0], argv[1:], vars), },
      env,
    ),
    prompt: fields => @prompt.task_prompt(env, Reviewer, fields),
    save: (path, data) => @store.save_json(path, data, exclusive=false),
  }
}

///|
/// Reads a review request, whose checkout may be any repository's top level because no app project is involved.
async fn read_request(
  ctx : Context,
  path : String,
) -> @request.ReviewRequest raise @failure.TaskFailed {
  let text = @store.read_regular_text(path) catch {
    failed => @failure.fail(failed.user_message())
  }
  let json = @jsonio.parse(text) catch {
    _ => @failure.fail("\{path} is not valid JSON")
  }
  @request.ReviewRequest::from_json(json, Cloud, ctx.probe, ctx.git)
}

///|
/// Sends the candidate to the task's reviewer, in a new Codex thread the first time and in the same one after.
async fn reviewed(
  ctx : Context,
  args : @args.ReviewArgs,
  directory : String,
  request : @request.ReviewRequest,
) -> Json raise @failure.TaskFailed {
  let records = @store.read_records(directory)
  @store.settle_pending(
    records,
    recover_of(args.recover),
    blocked=pending => {
      "the review of head \{as_text(field(pending, "head"))} did not report back: \{recovery_hint}"
    },
    nothing_pending="--recover applies only when a review is pending",
  )
  let state = records.state
  let previous = match field_of(state, "candidate") {
    Object(members) => Some(members)
    _ => None
  }
  // The prompt shows a worker chat ID of any type as JS writes it, while the saved candidate keeps the value as it came.
  let named_chat = match request.worker_chat_id {
    None | Some(String(_)) => request
    Some(other) => request.with_worker_chat_id(js_text(other))
  }
  let candidate = named_chat.candidate(previous, args.update_base, ctx.git)
  let data = with_chat_id(candidate.to_json(), request.worker_chat_id)
  if previous is Some(previous) {
    check_continuation(state, previous, data)
  }
  let fields = candidate.reviewer_fields("Cloud", ctx.probe)
  let prompt = (ctx.prompt)(fields)
  let launch = Launch::of_env(ctx.env)
  let reviewer = reviewer_of(state)
  let argv = review_argv(reviewer, request.checkout, args.model, args.thinking)
  (ctx.save)(
    records.pending_path,
    Json::object({
      "reviewer": match reviewer {
        Some(id) => Json::string(id)
        None => Json::null()
      },
      "base": Json::string(candidate.base),
      "head": Json::string(candidate.head),
      "startedAt": Json::string(@store.now_iso()),
    }),
  )
  let ran = Ok(
    @process.run_process(
      launch.bin,
      argv[:],
      prompt,
      cwd=request.checkout,
      env=ctx.env.to_map(),
      timeout_ms=launch.timeout_ms,
      kill_grace_ms=launch.kill_grace_ms,
    ),
  ) catch {
    failed => Err(failed)
  }
  let unsent = () => @store.remove_record(records.pending_path)
  let (thread, answer) = review_reply(ran, reviewer, unsent, () => {
    let forgotten = match state {
      Some(Object(members)) => {
        let kept = members.copy()
        kept["reviewer"] = Json::null()
        kept["updatedAt"] = Json::string(@store.now_iso())
        kept
      }
      _ =>
        {
          "reviewer": Json::null(),
          "updatedAt": Json::string(@store.now_iso()),
        }
    }
    (ctx.save)(records.state_path, Json::object(forgotten))
  })
  let heads = match field_of(state, "heads") {
    Array(items) => items.copy()
    _ => []
  }
  heads.push(Json::string(candidate.head))
  let verdict = match verdict_of(answer) {
    Some(verdict) => Json::string(verdict)
    None => Json::null()
  }
  let saved = Ok(
    (ctx.save)(
      records.state_path,
      Json::object({
        "reviewer": Json::string(thread),
        "candidate": data,
        "verdict": verdict,
        "heads": Json::array(heads),
        "updatedAt": Json::string(@store.now_iso()),
      }),
    ),
  ) catch {
    failed => Err(failed)
  }
  // The pending record stays, so the review is not taken as done; its answer is still shown.
  if saved is Err(failed) {
    @failure.fail(
      "\{failed.message()}; reviewer \{thread} answered, but it was not recorded, \{recovery_hint}. Its answer:\n\{answer}",
    )
  }
  unsent()
  Json::object({
    "status": Json::string("completed"),
    "verdict": verdict,
    "taskId": Json::string(request.task_id),
    "base": Json::string(candidate.base),
    "head": Json::string(candidate.head),
    "reviewer": Json::string(thread),
    "answer": Json::string(answer),
    "state": Json::string(records.state_path),
  })
}

///|
fn with_chat_id(data : Json, id : Json?) -> Json {
  match (data, id) {
    (Object(members), Some(id)) => {
      members["workerChatId"] = id
      data
    }
    _ => data
  }
}

///|
/// What `String(value)` gives in JS.
fn js_text(value : Json) -> String {
  match value {
    Null => "null"
    String(text) => text
    Array(items) =>
      items.map(item => if item is Null { "" } else { js_text(item) }).join(",")
    Object(_) => "[object Object]"
    other => @jsonio.stringify(other)
  }
}

///|
fn recover_of(recover : @args.RecoverMode?) -> @store.Recover? {
  match recover {
    Some(Discard) => Some(Discard)
    None => None
  }
}

///|
/// A review session keeps its task, worker AI and checkout.
/// A head the reviewer could not judge is sent again once what it lacked is given, such as a document it could not read.
fn check_continuation(
  state : Json?,
  previous : Map[String, Json],
  data : Json,
) -> Unit raise @failure.TaskFailed {
  @session.check_kept(Json::object(previous), data, [
    "taskId", "workerAI", "checkout",
  ])
  let judged = match field_of(state, "verdict") {
    String(verdict) => verdict != "判定保留"
    _ => false
  }
  let head = field(data, "head")
  let reviewed = match (previous.get("head"), head) {
    (Some(String(before)), String(now)) => before == now
    _ => false
  }
  if judged && reviewed {
    @failure.fail(
      "head \{as_text(head)} was already reviewed by \{as_text(field_of(state, "reviewer"))}; commit a fix before asking again",
    )
  }
}

///|
fn reviewer_of(state : Json?) -> String? {
  match field_of(state, "reviewer") {
    String(id) if is_thread_id(id) => Some(id)
    _ => None
  }
}

///|
/// What a finished Codex run answered.
/// A run that reviewed nothing clears the pending record so the candidate can be sent again; one whose result is unknown leaves it.
fn review_reply(
  ran : Result[@boundary.ProcessRun, @boundary.ProcessRunFailed],
  reviewer : String?,
  unsent : () -> Unit raise @failure.TaskFailed,
  forget_reviewer : () -> Unit raise @failure.TaskFailed,
) -> (String, String) raise @failure.TaskFailed {
  let run = match ran {
    Ok(run) => run
    Err(@boundary.ProcessRunFailed(started~, message~)) => {
      if !started {
        unsent()
      }
      @failure.fail(
        if started {
          "\{message}; \{recovery_hint}"
        } else {
          message
        },
      )
    }
  }
  let reply = reply_of(run.stdout)
  // A stopped run may have started its reviewer, which is named so it can be checked.
  if !(run.ended is Exit) {
    let started = match reply.thread_id {
      Some(id) => Some(id)
      None => reviewer
    }
    let in_reviewer = match started {
      Some(id) => " in reviewer \{id}"
      None => ""
    }
    @failure.fail(
      "codex was stopped (\{stop_reason(run.ended)})\{in_reviewer}; \{recovery_hint}",
    )
  }
  // A run that failed or never named its thread reviewed nothing, so the candidate can be sent again.
  guard run.status == 0 && reply.failure is None && reply.answer is Some(answer) else {
    unsent()
    // The reviewer's record lives in this machine's Codex home, which a rebuilt Cloud machine no longer has.
    if reviewer is Some(id) && run.stderr.contains(NO_ROLLOUT) {
      forget_reviewer()
      @failure.fail(
        "reviewer \{id} is gone from this machine; run review again to start a new reviewer",
      )
    }
    let cause = match reply.failure {
      Some(failure) => failure
      None => run.stderr
    }
    @failure.fail("codex did not review (exit \{run.status}): \{detail(cause)}")
  }
  let thread = match reply.thread_id {
    Some(id) => id
    None =>
      match reviewer {
        Some(id) => id
        None => {
          unsent()
          @failure.fail("codex answered without naming its thread")
        }
      }
  }
  (thread, answer)
}

///|
/// Passes a message, such as a question the user asked in the reviewer's chat, to the task's reviewer, answering with its reply.
/// The reviewer's verdict and the reviewed head stay as they were.
async fn asked(
  ctx : Context,
  ask : String,
  directory : String,
  request : @request.ReviewRequest,
) -> Json raise @failure.TaskFailed {
  let message = @store.read_regular_text(ask) catch {
    failed => @failure.fail(failed.user_message())
  }
  if @text.js_trim(message) == "" {
    @failure.fail("the --ask file is empty")
  }
  let state = @store.read_records(directory).state
  guard reviewer_of(state) is Some(reviewer) else {
    @failure.fail("this task has no reviewer yet; run review first")
  }
  let launch = Launch::of_env(ctx.env)
  let run = @process.run_process(
    launch.bin,
    ask_argv(reviewer)[:],
    message,
    cwd=request.checkout,
    env=ctx.env.to_map(),
    timeout_ms=launch.timeout_ms,
    kill_grace_ms=launch.kill_grace_ms,
  ) catch {
    @boundary.ProcessRunFailed(message~, ..) => @failure.fail(message)
  }
  if !(run.ended is Exit) {
    @failure.fail(
      "codex was stopped (\{stop_reason(run.ended)}) in reviewer \{reviewer}; it may have answered, so check before asking again",
    )
  }
  let reply = reply_of(run.stdout)
  guard run.status == 0 && reply.failure is None && reply.answer is Some(answer) else {
    let cause = match reply.failure {
      Some(failure) => failure
      None => run.stderr
    }
    @failure.fail(
      "reviewer \{reviewer} did not answer (exit \{run.status}): \{detail(cause)}",
    )
  }
  let reviewed = field_of(state, "candidate")
  Json::object({
    "status": Json::string("completed"),
    "kind": Json::string("reply"),
    // Tells this reply from another of the same text, such as the same answer to a question asked again.
    "askedAt": Json::string(@store.now_iso()),
    "verdict": match verdict_of(answer) {
      Some(verdict) => Json::string(verdict)
      None => Json::null()
    },
    "taskId": Json::string(request.task_id),
    "head": field(reviewed, "head"),
    "reviewer": Json::string(reviewer),
    "answer": Json::string(answer),
  })
}

///|
/// A member of a record, Null when the record has none or is not an object.
fn field(record : Json, key : String) -> Json {
  match record {
    Object(members) => members.get(key).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
fn field_of(record : Json?, key : String) -> Json {
  match record {
    Some(record) => field(record, key)
    None => Json::null()
  }
}
