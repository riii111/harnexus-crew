///|
fn no_which(_ : String) -> String? {
  None
}

///|
fn codex_env(pairs : Array[(String, String)]) -> @environment.Env {
  env_of([("HOME", "/h"), ..pairs])
}

///|
test "the Codex App host sends through the bridge and renames threads" {
  let host = host_of(codex_env([("CODEX_HOME", "/cx")]), which=no_which)
  inspect(host.thread_variable, content="CODEX_THREAD_ID")
  inspect(host.worktrees, content="/cx/worktrees")
  inspect(host.renames_threads, content="true")
  match host.thinking {
    Some(thinking) => {
      assert_eq(thinking.worker, "high")
      assert_eq(thinking.reviewer, "medium")
    }
    None => fail("the Codex App host has a default thinking")
  }
  inspect((host.reply_to)("Claude"), content="Claude")
  inspect((host.reply_to)("Codex"), content="Codex")
}

///|
test "the T3 Code host has its own thread variable, folder and reply template, and no thinking" {
  let host = host_of(
    codex_env([("T3CODE_THREAD_ID", "t"), ("T3CODE_HOME", "/data/t3")]),
    which=no_which,
  )
  inspect(host.thread_variable, content="T3CODE_THREAD_ID")
  inspect(host.worktrees, content="/data/t3/worktrees")
  inspect(host.renames_threads, content="false")
  assert_true(host.thinking is None)
  inspect((host.reply_to)("Claude"), content="T3")
  inspect((host.reply_to)("Codex"), content="T3")
  inspect(
    host_of(codex_env([("T3CODE_THREAD_ID", "t")]), which=no_which).worktrees,
    content="/h/.t3/worktrees",
  )
}

///|
async test "each host sends to its own app" {
  let off = ("HARNEXUS_CALL_SOCKET", "off")
  let codex = host_of(codex_env([off]), which=no_which)
  inspect(
    json_text((codex.call)("w1", "name_thread", {}).to_json()),
    content="{\"outcome\":\"not_sent\",\"error\":\"the call socket is off (HARNEXUS_CALL_SOCKET=off)\"}",
  )
  let t3 = host_of(codex_env([off, ("T3CODE_THREAD_ID", "t")]), which=no_which)
  inspect(
    json_text((t3.call)("w1", "name_thread", {}).to_json()),
    content="{\"outcome\":\"unsupported\",\"error\":\"T3 Code does not offer name_thread\"}",
  )
}

///|
/// Runs `body` with a home whose review-home folder exists.
async fn with_home(
  name : String,
  body : async (String, String) -> Unit,
) -> Unit {
  let home = scratch(name)
  let review_home = "\{home}/review-home"
  @store.prepare_directory(review_home) catch {
    failed => abort(failed.user_message())
  }
  errdefer @async.protect_from_cancel(() => remove_tree(home))
  body(home, @store.real_path_or_self(review_home))
  remove_tree(home)
}

///|
async fn review_project_of(host : Host) -> String {
  (host.review_project)("w1") catch {
    @failure.TaskFailed(message) => "failed: \{message}"
  }
}

///|
async test "a T3 Code reviewer runs in the review home folder, without asking the app" {
  with_home("host-1", (home, real) => {
    let host = host_of(
      env_of([("HOME", home), ("T3CODE_THREAD_ID", "t")]),
      which=no_which,
    )
    assert_eq(review_project_of(host), real)
  })
}

///|
async test "a Codex App reviewer runs in the project whose folder is the review home" {
  with_home("host-2", (home, real) => {
    let projects = "[{\"projectId\":\"p0\",\"path\":\"/elsewhere\"},{\"projectId\":3,\"path\":\"\{home}/review-home\"},{\"projectId\":\"p1\",\"path\":\"\{home}/review-home\"},{\"projectId\":\"p2\",\"path\":\"\{home}/review-home\"}]"
    with_bridge(
      "host-2",
      offering(
        ["list_projects"],
        Some(
          "{\"version\":1,\"outcome\":\"done\",\"result\":{\"projects\":\{projects}}}",
        ),
      ),
      (path, lines) => {
        let host = host_of(
          env_of([("HOME", home), ("HARNEXUS_CALL_SOCKET", path)]),
          which=no_which,
        )
        assert_eq(review_project_of(host), "p1")
        assert_eq(
          lines[1],
          "{\"version\":1,\"threadId\":\"w1\",\"tool\":\"list_projects\",\"arguments\":{}}",
        )
        ignore(real)
      },
    )
  })
}

///|
async test "a Codex App reviewer needs the review home added as a project" {
  with_home("host-3", (home, real) => {
    with_bridge(
      "host-3",
      offering(
        ["list_projects"],
        Some(
          "{\"version\":1,\"outcome\":\"done\",\"result\":{\"projects\":[]}}",
        ),
      ),
      (path, _) => {
        let host = host_of(
          env_of([("HOME", home), ("HARNEXUS_CALL_SOCKET", path)]),
          which=no_which,
        )
        assert_eq(
          review_project_of(host),
          "failed: add \{real} to the Codex app as a project, so reviewers run there instead of in a worktree of their own",
        )
      },
    )
  })
}

///|
async test "a Codex App reviewer reports a project list the bridge could not give" {
  with_home("host-4", (home, _) => {
    let host = host_of(
      env_of([("HOME", home), ("HARNEXUS_CALL_SOCKET", "off")]),
      which=no_which,
    )
    assert_eq(
      review_project_of(host),
      "failed: list_projects failed: {\"outcome\":\"not_sent\",\"error\":\"the call socket is off (HARNEXUS_CALL_SOCKET=off)\"}",
    )
  })
}
