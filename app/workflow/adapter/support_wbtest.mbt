///|
let session : String = "session_01AbC"

///|
let parent : String = "parent-chat"

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
/// A new empty directory under the temporary directory, for one test to fill.
fn scratch(name : String) -> String {
  let directory = "\{temp_base()}/hxd-\{@testkit.pid()}-\{name}-\{@store.new_uuid()[:8]}"
  @store.prepare_directory(directory) catch {
    failed => abort(failed.user_message())
  }
  directory
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
/// The folders one machine's adapters share.
priv struct Place {
  reviews : String
  observe : String
  review_home : String
}

///|
let gate : @async.Mutex = @async.Mutex()

///|
/// The test driver runs up to ten tests at once on one thread.
/// A test that counts descriptors would see the others' cleanup children, so each test runs alone.
async fn with_place(name : String, body : async (Place) -> Unit) -> Unit {
  gate.acquire()
  defer gate.release()
  let root = scratch(name)
  defer @async.protect_from_cancel(() => remove_tree(root))
  let at = {
    reviews: "\{root}/cloud-reviews",
    observe: "\{root}/observe",
    review_home: "\{root}/review-home",
  }
  @store.prepare_directory(at.review_home) catch {
    failed => abort(failed.user_message())
  }
  body(at)
}

///|
fn write_file(path : String, text : String) -> Unit {
  @store.prepare_directory(@path.dirname(path)) catch {
    failed => abort(failed.user_message())
  }
  @store.write_atomic(path, text) catch {
    failed => abort(failed.user_message())
  }
}

///|
fn read_file(path : String) -> String {
  let text = @store.read_text_if_exists(path) catch {
    failed => abort(failed.user_message())
  }
  text.unwrap_or("")
}

///|
fn read_json_file(path : String) -> Json {
  @jsonio.parse(read_file(path)) catch {
    _ => abort("not JSON: \{path}")
  }
}

///|
fn json_of(text : String) -> Json {
  @jsonio.parse(text) catch {
    _ => abort("not JSON: \{text}")
  }
}

///|
fn text_of(value : Json) -> String {
  value.stringify()
}

///|
fn str(text : String) -> Json {
  Json::string(text)
}

///|
/// A prompt record of a Cloud session.
fn prompt(uuid : String, text : String) -> Json {
  object([
    ("type", str("user")),
    ("uuid", str(uuid)),
    ("message", object([("role", str("user")), ("content", str(text))])),
  ])
}

///|
/// The two records a tool call leaves: the call and its result.
fn ran(id : String, content : String) -> Array[Json] {
  [
    object([
      ("type", str("assistant")),
      ("uuid", str("a-\{id}")),
      (
        "message",
        object([
          ("role", str("assistant")),
          (
            "content",
            Json::array([
              object([
                ("type", str("tool_use")),
                ("id", str(id)),
                ("name", str("Bash")),
                ("input", object([])),
              ]),
            ]),
          ),
        ]),
      ),
    ]),
    object([
      ("type", str("user")),
      ("uuid", str("u-\{id}")),
      (
        "message",
        object([
          ("role", str("user")),
          (
            "content",
            Json::array([
              object([
                ("type", str("tool_result")),
                ("tool_use_id", str(id)),
                ("content", str(content)),
                ("is_error", Json::boolean(false)),
              ]),
            ]),
          ),
        ]),
      ),
    ]),
  ]
}

///|
/// Records of a Cloud session in which the reviewer judged a head.
fn judged(head : String, reviewer~ : String = "R1") -> Array[Json] {
  let output = object([
    ("status", str("completed")),
    ("verdict", str("LGTM")),
    ("taskId", str("harnexus-1")),
    ("base", str("b1")),
    ("head", str(head)),
    ("reviewer", str(reviewer)),
    ("answer", str("判定: LGTM \{head}")),
    ("state", str("/tmp/state.json")),
  ])
  ran("t-\{head}-\{reviewer}", text_of(output))
}

///|
fn review_of_head(
  head : String,
  reviewer~ : String = "R1",
) -> @host.CloudReview {
  @host.reviews_in(judged(head, reviewer~))[0]
}

///|
fn two_reviews() -> Array[Json] {
  [..judged("aaa1111"), ..judged("bbb2222")]
}

///|
/// The result of a `list_projects` request that names the review home.
fn projects_answer(at : Place) -> Json {
  let listing = object([
    (
      "projects",
      Json::array([
        object([
          ("projectId", str("review-home")),
          ("path", str(at.review_home)),
        ]),
      ]),
    ),
  ])
  object([
    ("outcome", str("done")),
    (
      "result",
      object([
        (
          "content",
          Json::array([
            object([("type", str("text")), ("text", str(text_of(listing)))]),
          ]),
        ),
      ]),
    ),
  ])
}

///|
fn done_answer() -> Json {
  object([("outcome", str("done"))])
}

///|
fn done_with_chat(thread_id : String) -> Json {
  object([("outcome", str("done")), ("threadId", str(thread_id))])
}

///|
fn outcome_answer(outcome : String, reason~ : String? = None) -> Json {
  match reason {
    Some(reason) => object([("outcome", str(outcome)), ("reason", str(reason))])
    None => object([("outcome", str(outcome))])
  }
}

///|
/// Handling lines the way the serving loop does, but one at a time, so a test can say what the bridge says and look at what came of it.
async fn Adapter::receive(self : Adapter, raw : String) -> Unit noraise {
  match self.accept(raw) {
    Handled => ()
    Later(work) => work()
  }
}

///|
/// One connection of a fake bridge with an adapter: the lines the adapter sent, and the bridge's answers to its requests.
priv struct Link {
  adapter : Adapter
  sent : Array[Json]
  logs : Array[Json]
  mut events : Int32
}

///|
fn connect(
  at : Place,
  group : @async.TaskGroup,
  answer~ : (Json) -> Json = _ => done_answer(),
  silent~ : Bool = false,
) -> Link {
  let sent = []
  let logs = []
  let cell : Ref[Adapter?] = Ref(None)
  let locks = "\{at.observe}/locks"
  let adapter = Adapter::new({
    adapter_id: "taskctl",
    send: text => {
      let line = json_of(text)
      sent.push(line)
      if text_member(line, "type") == Some("request") && !silent {
        let reply = answer(line)
        group.spawn_bg(no_wait=true, () => {
          @async.sleep(1)
          let members = [
            ("v", Json::number(1.0)),
            ("type", str("response")),
            ("id", field(line, "id").unwrap()),
            ("bridgeId", str("b1")),
          ]
          if reply is Object(fields) {
            for name, value in fields {
              members.push((name, value))
            }
          }
          cell.val.unwrap().receive(text_of(object(members)))
        })
      }
    },
    store: ReviewStore::new(at.reviews, locks),
    observations: Observations::new(at.observe),
    locks,
    review_home: at.review_home,
    log: entry => logs.push(object(entry)),
  })
  cell.val = Some(adapter)
  group.spawn_bg(no_wait=true, () => adapter.run_jobs())
  { adapter, sent, logs, events: 0, }
}

///|
async fn Link::say(self : Link, line : Array[(String, Json)]) -> Unit {
  let framed = [("v", Json::number(1.0)), ..line]
  self.adapter.receive(text_of(object(framed)))
  @async.sleep(5)
}

///|
async fn Link::start(self : Link, mode : String) -> Unit {
  self.say([
    ("type", str("hello")),
    ("bridgeId", str("b1")),
    ("adapterId", str("taskctl")),
    ("mode", str(mode)),
    ("versions", Json::array([Json::number(1.0)])),
  ])
  self.say(ready_line([]))
}

///|
fn ready_line(bindings : Array[Json]) -> Array[(String, Json)] {
  [
    ("type", str("ready")),
    ("bridgeId", str("b1")),
    ("bindings", Json::array(bindings)),
    ("pending", Json::array([])),
    ("conflicts", Json::array([])),
  ]
}

///|
async fn Link::records(
  self : Link,
  phase : String,
  records : Array[Json],
  linked_at? : String,
  shown_before? : String,
  session_id~ : String = session,
) -> Unit {
  self.events += 1
  let line = [
    ("type", str("event")),
    ("event", str("session_records")),
    ("eventId", str("e\{self.events}")),
    ("sessionId", str(session_id)),
    ("parentThreadId", str(parent)),
    ("link", str(parent)),
    ("phase", str(phase)),
    ("shownBefore", text_or_null(shown_before)),
    ("records", Json::array(records)),
  ]
  if phase == "linked" {
    line.push(("linkedAt", text_or_null(linked_at)))
  }
  self.say(line)
}

///|
fn Link::requests(self : Link, op? : String) -> Array[Json] {
  self.sent.filter(line => {
    text_member(line, "type") == Some("request") &&
    (op is None || text_member(line, "op") == op)
  })
}

///|
fn Link::lines_of_type(self : Link, kind : String) -> Array[Json] {
  self.sent.filter(line => text_member(line, "type") == Some(kind))
}

///|
fn Link::texts(self : Link, op : String) -> Array[String] {
  self.requests(op~).map(line => text_member(line, "text").unwrap_or(""))
}

///|
fn turn_line(
  turn_id : String,
  thread_id : String,
  conversation : String,
  kind : String,
  text~ : String = "",
) -> Array[(String, Json)] {
  [
    ("type", str("event")),
    ("event", str("turn")),
    ("turnId", str(turn_id)),
    ("threadId", str(thread_id)),
    ("conversationId", str(conversation)),
    ("kind", str(kind)),
    ("text", str(text)),
  ]
}

///|
fn list_names(directory : String) -> Array[String] {
  let listed = @store.list_directory_if_exists(directory) catch { _ => None }
  let names = listed.unwrap_or([])
  names.sort_by(String::lexical_compare)
  names
}

///|
fn read_pending_keys(link : Link) -> Array[String] {
  let waiting = link.adapter.deps.observations.read_pending() catch {
    failed => abort(failed.message())
  }
  waiting.map(entry => entry.review.key)
}
