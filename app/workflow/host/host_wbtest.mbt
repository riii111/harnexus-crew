///|
fn no_which(_ : String) -> String? {
  None
}

///|
fn env_with_home(pairs : Array[(String, String)]) -> @environment.Env {
  @apptestkit.env_of([("HOME", "/h"), ..pairs])
}

///|
/// Runs `body` with a home whose review-home folder exists.
async fn with_home(name : String, body : async (String) -> Unit) -> Unit {
  let home = @testkit.scratch(name)
  let review_home = "\{home}/review-home"
  @store.prepare_directory(review_home) catch {
    failed => abort(failed.user_message())
  }
  errdefer @async.protect_from_cancel(() => @testkit.remove_tree(home))
  body(home)
  @testkit.remove_tree(home)
}

///|
async fn resolve_review_project(host : Host) -> String {
  (host.review_project)("w1") catch {
    @failure.TaskFailed(message) => "failed: \{message}"
  }
}

///|
test "the Codex App host's thread variable is CODEX_THREAD_ID" {
  inspect(codex_app_host().thread_variable, content="CODEX_THREAD_ID")
}

///|
test "the Codex App host keeps worktrees under the worktrees folder of CODEX_HOME" {
  inspect(codex_app_host().worktrees, content="/cx/worktrees")
}

///|
test "the Codex App host can rename threads" {
  inspect(codex_app_host().renames_threads, content="true")
}

///|
test "the Codex App host defaults to high thinking for the worker and medium for the reviewer" {
  assert_eq(
    codex_app_host().thinking.map(thinking => {
      (thinking.worker, thinking.reviewer)
    }),
    Some(("high", "medium")),
  )
}

///|
test "the Codex App host replies in the template named after the worker's AI" {
  let host = codex_app_host()

  inspect((host.reply_to)("Claude"), content="Claude")
  inspect((host.reply_to)("Codex"), content="Codex")
}

///|
test "the T3 Code host's thread variable is T3CODE_THREAD_ID" {
  inspect(t3_code_host().thread_variable, content="T3CODE_THREAD_ID")
}

///|
test "the T3 Code host keeps worktrees under the worktrees folder of T3CODE_HOME" {
  inspect(t3_code_host().worktrees, content="/data/t3/worktrees")
}

///|
test "the T3 Code host keeps worktrees under .t3 in the home folder when T3CODE_HOME is unset" {
  let host = host_of(env_with_home([("T3CODE_THREAD_ID", "t")]), which=no_which)

  inspect(host.worktrees, content="/h/.t3/worktrees")
}

///|
test "the T3 Code host cannot rename threads" {
  inspect(t3_code_host().renames_threads, content="false")
}

///|
test "the T3 Code host has no default thinking" {
  assert_eq(
    t3_code_host().thinking.map(thinking => (thinking.worker, thinking.reviewer)),
    None,
  )
}

///|
test "the T3 Code host replies in the T3 template whichever AI the worker is" {
  let host = t3_code_host()

  inspect((host.reply_to)("Claude"), content="T3")
  inspect((host.reply_to)("Codex"), content="T3")
}

///|
async test "a call from the Codex App host goes to the app's bridge, which reports the switched-off call socket as not sent" {
  let host = host_of(
    env_with_home([("HARNEXUS_CALL_SOCKET", "off")]),
    which=no_which,
  )

  inspect(
    json_text((host.call)("w1", "name_thread", {}).to_json()),
    content="{\"outcome\":\"not_sent\",\"error\":\"the call socket is off (HARNEXUS_CALL_SOCKET=off)\"}",
  )
}

///|
async test "a call from the T3 Code host goes to the t3 CLI, which does not offer name_thread" {
  let host = host_of(
    env_with_home([("HARNEXUS_CALL_SOCKET", "off"), ("T3CODE_THREAD_ID", "t")]),
    which=no_which,
  )

  inspect(
    json_text((host.call)("w1", "name_thread", {}).to_json()),
    content="{\"outcome\":\"unsupported\",\"error\":\"T3 Code does not offer name_thread\"}",
  )
}

///|
async test "a Codex App reviewer runs in the project whose id is text and whose folder is the review home" {
  with_review_projects("review-project", (host, _) => {
    assert_eq(resolve_review_project(host), "p1")
  })
}

///|
async test "a Codex App reviewer's project is found by asking the app for its projects as the worker's thread" {
  with_review_projects("review-request", (host, lines) => {
    assert_eq(resolve_review_project(host), "p1")
    assert_eq(lines, [
      "{\"version\":1,\"threadId\":\"w1\",\"tool\":\"list_projects\",\"arguments\":{}}",
    ])
  })
}

///|
fn codex_app_host() -> Host {
  host_of(env_with_home([("CODEX_HOME", "/cx")]), which=no_which)
}

///|
fn t3_code_host() -> Host {
  host_of(
    env_with_home([("T3CODE_THREAD_ID", "t"), ("T3CODE_HOME", "/data/t3")]),
    which=no_which,
  )
}

///|
async fn with_review_projects(
  name : String,
  body : async (Host, Array[String]) -> Unit,
) -> Unit {
  with_home(name, home => {
    let projects = "[{\"projectId\":\"p0\",\"path\":\"/elsewhere\"},{\"projectId\":3,\"path\":\"\{home}/review-home\"},{\"projectId\":\"p1\",\"path\":\"\{home}/review-home\"},{\"projectId\":\"p2\",\"path\":\"\{home}/review-home\"}]"
    with_bridge(
      name,
      _ => {
        Some(
          "{\"version\":1,\"outcome\":\"done\",\"result\":{\"projects\":\{projects}}}",
        )
      },
      (path, lines) => {
        let host = host_of(
          @apptestkit.env_of([("HOME", home), ("HARNEXUS_CALL_SOCKET", path)]),
          which=no_which,
        )
        body(host, lines)
      },
    )
  })
}

///|
fn socket_path(name : String) -> String {
  "\{@testkit.temp_base()}/hxa-\{@testkit.pid()}-\{name}.sock"
}

///|
/// A bridge listening on a Unix socket, removed with the test.
/// `handle` runs once for each accepted connection.
async fn with_server(
  name : String,
  handle : async (@raw_fd.RawFdStream) -> Unit,
  body : async (String) -> Unit,
) -> Unit {
  let path = socket_path(name)
  let listener = @testkit.listen(path)
  defer {
    @testkit.close_fd(listener)
    @testkit.remove_file(path)
  }
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      while true {
        match @testkit.accept(listener) {
          Some(fd) =>
            group.spawn_bg(no_wait=true, () => {
              let stream = @raw_fd.RawFdStream(fd)
              defer stream.close()
              handle(stream)
            })
          None => @async.sleep(5)
        }
      }
    })
    body(path)
  })
}

///|
/// The request line, as the bridge reads it; None when the peer closed before sending one.
async fn read_request(stream : @raw_fd.RawFdStream) -> String? {
  let line = stream.read_until(b"\n") catch { _ => None }
  line.map(bytes => @utf8.decode_lossy(bytes))
}

///|
/// A bridge that records the lines it receives and answers each by `rule`, or not at all for None.
async fn with_bridge(
  name : String,
  rule : (String) -> String?,
  body : async (String, Array[String]) -> Unit,
) -> Unit {
  let lines = []
  with_server(
    name,
    stream => {
      let line = read_request(stream).unwrap_or("")
      lines.push(line)
      match rule(line) {
        Some(reply) => stream.write(@utf8.encode(reply + "\n"))
        // A bridge that does not answer keeps the connection open.
        None => @async.sleep(60000)
      }
    },
    path => body(path, lines),
  )
}
