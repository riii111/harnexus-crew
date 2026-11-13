///|
let gate : @async.Mutex = @async.Mutex()

///|
/// The test driver runs up to ten tests at once on one thread.
/// A test that times a deadline or counts a child's runs holds the gate, so another test's sockets and sleeps do not show up in it.
async fn serial(body : async () -> Unit) -> Unit {
  gate.acquire()
  defer gate.release()
  body()
}

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
/// A new empty directory for one test to fill.
fn scratch(name : String) -> String {
  let directory = "\{temp_base()}/hxa-\{@testkit.pid()}-\{name}-\{@store.new_uuid()[:8]}"
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
fn socket_path(name : String) -> String {
  "\{temp_base()}/hxa-\{@testkit.pid()}-\{name}.sock"
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
fn env_of(pairs : Array[(String, String)]) -> @environment.Env {
  let vars = Map([])
  for pair in pairs {
    let (name, value) = pair
    vars[name] = value
  }
  @environment.Env::new(vars)
}

///|
fn json_text(value : Json) -> String {
  value.stringify()
}

///|
fn parse(text : String) -> Json {
  @jsonio.parse(text) catch {
    _ => abort("not JSON: \{text}")
  }
}
