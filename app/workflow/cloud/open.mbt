///|
pub async fn open_chat(
  args : @workflow.CloudInput,
  env : @environment.Env,
) -> Json raise @failure.TaskFailed {
  @workflow.refuse_in_cloud(env, "cloud")
  @workflow.refuse_in_t3(
    env, "cloud", "Open a Cloud session from the Codex App instead",
  )

  if args.project is Some(project) {
    ignore(@request.check_single_line(project, "--project"))
  }

  let caller = @request.read_caller_id(env)

  let prompt = match args.prompt_file {
    None => None
    Some(path) => {
      let text = @store.read_regular_text(path) catch {
        failed => @failure.fail(failed.user_message())
      }

      if @text.is_blank(text) {
        @failure.fail("the prompt file is empty")
      }

      Some(text)
    }
  }

  let cwd = match @env.current_dir() {
    Some(directory) => directory
    None => @failure.fail("cannot read the current directory")
  }

  let sent : Map[String, Json] = { "cwd": Json::string(cwd) }
  add(sent, "link", args.link)
  add(sent, "prompt", prompt)
  add(sent, "projectId", args.project)
  add(sent, "title", args.title)
  add(sent, "model", args.model)
  add(sent, "thinking", args.thinking)
  let answer = @bridge.call_app(env, caller, "cloud_open", sent)
  if answer.outcome == "done" {
    if answer.fields.get("result") is Some(Object(_) as result) {
      return result
    }
  }

  // unknown and chat_not_opened leave a session that may run, so the advice is never to send it again.
  let again = if answer.is_unsent() {
    "nothing was sent"
  } else {
    "never resend; check the app"
  }

  @failure.fail(
    "cloud_open \{answer.outcome} (\{again}): \{@jsonio.as_text(shown(answer))}",
  )
}

///|
fn add(sent : Map[String, Json], key : String, value : String?) -> Unit {
  if value is Some(value) {
    sent[key] = Json::string(value)
  }
}

///|
fn shown(answer : @bridge.CallAnswer) -> Json {
  for key in ["message", "error"] {
    match answer.fields.get(key) {
      Some(Null) | None => ()
      Some(value) => return value
    }
  }

  answer.to_json()
}
