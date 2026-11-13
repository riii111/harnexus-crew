///|
priv struct Context {
  env : @environment.Env
  probe : @request.FileProbe
  git : @git.Git
  prompt : (Map[String, String]) -> String raise @failure.TaskFailed
  save : (String, Json) -> Unit raise @failure.TaskFailed
}

///|
/// Reviews in a Claude Code cloud session with a Codex CLI run beside the worker, answering with its result instead of a chat in the app.
/// With `ask`, passes that message to the same reviewer instead.
pub async fn review(
  args : @workflow.ReviewInput,
  env : @environment.Env,
) -> Json raise @failure.TaskFailed {
  review_in(Context::of_env(env), args)
}

///|
async fn review_in(
  ctx : Context,
  args : @workflow.ReviewInput,
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
    "\{request.checkout}\u{0}\{request.task_id}",
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
async fn reviewed(
  ctx : Context,
  args : @workflow.ReviewInput,
  directory : String,
  request : @request.ReviewRequest,
) -> Json raise @failure.TaskFailed {
  let records = @store.read_records(directory)
  match (records.pending, args.discard_pending) {
    (None, false) => ()
    (None, true) =>
      @failure.fail("--recover applies only when a review is pending")
    // Only the user, having checked what the lost send did, releases it.
    (Some(pending), false) =>
      @failure.fail(
        "the review of head \{@jsonio.as_text(@jsonio.field(pending, "head"))} did not report back: \{recovery_hint}",
      )
    (Some(_), true) => @store.remove_record(records.pending_path)
  }
  let state = records.state
  let previous = match field_of(state, "candidate") {
    Object(members) => Some(members)
    _ => None
  }
  let candidate = request.candidate(previous, args.update_base, ctx.git)
  let data = candidate.to_json()
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
      "reviewer \{reviewer} did not answer (exit \{run.status}): \{@text.excerpt(cause)}",
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
    "head": @jsonio.field(reviewed, "head"),
    "reviewer": Json::string(reviewer),
    "answer": Json::string(answer),
  })
}

///|
fn Context::of_env(env : @environment.Env) -> Context {
  {
    env,
    probe: @request.FileProbe::of_machine(),
    git: @git.Git::of_env(env),
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
  let json = @store.read_json(path)
  @request.ReviewRequest::from_json(json, Cloud, ctx.probe, ctx.git)
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
  let head = @jsonio.field(data, "head")
  let reviewed = match (previous.get("head"), head) {
    (Some(String(before)), String(now)) => before == now
    _ => false
  }
  if judged && reviewed {
    @failure.fail(
      "head \{@jsonio.as_text(head)} was already reviewed by \{@jsonio.as_text(field_of(state, "reviewer"))}; commit a fix before asking again",
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
/// reviewed nothing: Clears the pending record so the candidate can be sent again.
/// result unknown  : Leaves the pending record.
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
    @failure.fail(
      "codex did not review (exit \{run.status}): \{@text.excerpt(cause)}",
    )
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
fn field_of(record : Json?, key : String) -> Json {
  match record {
    Some(record) => @jsonio.field(record, key)
    None => Json::null()
  }
}
