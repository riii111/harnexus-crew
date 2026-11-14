///|
/// A scratch directory with stand-in commands in `bin` and the files they record into and replay from in `fake_dir`.
pub struct FakeCli {
  root : String
  fake_dir : String
  bin : String
}

///|
/// Runs `body` with a `FakeCli` whose `bin` holds a copy of the mock script `mock` from `test/native/mocks` under each name in `stand_ins`.
pub async fn with_fake_cli(
  name : String,
  mock~ : String,
  stand_ins~ : Array[String],
  body : async (FakeCli) -> Unit,
) -> Unit {
  let root = new_root(name)
  errdefer @async.protect_from_cancel(() => @os_testkit.remove_tree(root))
  let fake = { root, fake_dir: "\{root}/fake", bin: "\{root}/bin", }

  for directory in [fake.fake_dir, fake.bin] {
    @fs.mkdir(directory) catch {
      _ => abort("cannot create \{directory}")
    }
  }

  let script = "\{@env.current_dir().unwrap()}/test/native/mocks/\{mock}"
  let content = @fs.read_binary(script) catch {
    _ => abort("cannot read \{script}")
  }

  for stand_in in stand_ins {
    let path = "\{fake.bin}/\{stand_in}"
    @fs.write_binary(path, content, permission=0o755) catch {
      _ => abort("cannot write \{path}")
    }
  }

  body(fake)
  @os_testkit.remove_tree(root)
}

///|
/// Plans run `run` of the stand-in `name`; a stand-in that records without a name prefix is planned without `name`.
pub async fn FakeCli::plan(
  self : FakeCli,
  run : Int32,
  name? : String,
  out~ : String = "",
  exit~ : Int32 = 0,
  stderr? : String,
  sleep? : String,
) -> Unit {
  write_record(self.record_path("out.\{run}", name), out)
  write_record(self.record_path("exit.\{run}", name), exit.to_string())

  if stderr is Some(text) {
    write_record(self.record_path("stderr.\{run}", name), text)
  }

  if sleep is Some(seconds) {
    write_record(self.record_path("sleep.\{run}", name), seconds)
  }
}

///|
/// What run `run` of the stand-in `name` recorded as `what`, or "" when it recorded nothing.
pub async fn FakeCli::recorded(
  self : FakeCli,
  what : String,
  run : Int32,
  name? : String,
) -> String {
  let path = self.record_path("\{what}.\{run}", name)

  if @fs.exists(path) {
    @fs.read_text(path) catch {
      _ => abort("cannot read \{path}")
    }
  } else {
    ""
  }
}

///|
pub async fn FakeCli::args(
  self : FakeCli,
  run : Int32,
  name? : String,
) -> Array[String] {
  let lines = []

  for line in @text.js_trim(self.recorded("args", run, name?)).split("\n") {
    lines.push(line.to_owned())
  }

  lines
}

///|
pub async fn FakeCli::ran(self : FakeCli, name? : String) -> Bool {
  @fs.exists(self.record_path("count", name))
}

///|
/// An environment that finds the stand-ins on PATH and tells them where to record; `extra` overrides it.
pub fn FakeCli::env(
  self : FakeCli,
  extra : Array[(String, String)],
) -> @environment.Env {
  env_of(
    [
      ("PATH", "\{self.bin}:/usr/bin:/bin"),
      ("FAKE_DIR", self.fake_dir),
      ("HOME", self.root),
      ..extra,
    ],
  )
}

///|
fn FakeCli::record_path(
  self : FakeCli,
  file : String,
  name : String?,
) -> String {
  match name {
    Some(name) => "\{self.fake_dir}/\{name}.\{file}"
    None => "\{self.fake_dir}/\{file}"
  }
}

///|
async fn write_record(path : String, text : String) -> Unit {
  @fs.write_text(path, text) catch {
    _ => abort("cannot write \{path}")
  }
}

///|
let root_count : Ref[Int32] = Ref(0)

///|
async fn new_root(name : String) -> String {
  // `@os_testkit.scratch` ignores TMPDIR and so fails where only TMPDIR is writable, so the directory is made here.
  for _ in 0..<1000 {
    root_count.val += 1
    let path = "\{@os_testkit.temp_base()}/hx-\{name}.\{@os_testkit.pid()}.\{root_count.val}"

    if !@fs.exists(path) {
      @fs.mkdir(path, permission=0o700) catch {
        error => abort("cannot create \{path}: \{error}")
      }

      // A stand-in records its working directory as a resolved path, so the root is resolved to match it.
      return @fs.realpath(path) catch {
        error => abort("cannot resolve \{path}: \{error}")
      }
    }
  }

  abort("no free scratch directory for \{name}")
}
