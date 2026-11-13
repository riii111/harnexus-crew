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
async fn shell(program : String, args : Array[String]) -> Unit {
  ignore(
    @process.run_command(program, args, { "PATH": "/usr/bin:/bin" }) catch {
      _ => abort("cannot run \{program}")
    },
  )
}

///|
/// A directory holding stand-ins for pr-wake and its engine, and the files they record into.
struct Rig {
  root : String
  fake : String
  bin : String
}

///|
fn mock_script() -> String {
  "\{@env.current_dir().unwrap()}/test/native/mocks/pr-wake.sh"
}

///|
async fn with_rig(name : String, body : async (Rig) -> Unit) -> Unit {
  let made = "\{temp_base()}/hxp-\{@testkit.pid()}-\{name}-\{@store.new_uuid()[:8]}"
  @store.prepare_directory(made) catch {
    failed => abort(failed.user_message())
  }
  // The engine is looked up beside the resolved pr-wake, so the root is resolved first.
  let root = @store.real_path_or_self(made)
  let rig = { root, fake: "\{root}/fake", bin: "\{root}/bin", }
  errdefer @async.protect_from_cancel(() => shell("rm", ["-rf", root]))
  for directory in [rig.fake, rig.bin] {
    @store.prepare_directory(directory) catch {
      failed => abort(failed.user_message())
    }
  }
  for stand_in in ["pr-wake", "pr-wake-engine"] {
    shell("cp", [mock_script(), "\{rig.bin}/\{stand_in}"])
  }
  body(rig)
  shell("rm", ["-rf", root])
}

///|
fn Rig::ran(self : Rig, name : String) -> Bool {
  @store.path_exists("\{self.fake}/\{name}.count")
}

///|
/// An environment that finds the stand-ins on PATH and tells them where to record.
fn Rig::env(self : Rig, extra : Array[(String, String)]) -> @environment.Env {
  let vars = Map([])
  vars["PATH"] = "\{self.bin}:/usr/bin:/bin"
  vars["FAKE_DIR"] = self.fake
  vars["HOME"] = self.root
  for pair in extra {
    let (name, value) = pair
    vars[name] = value
  }
  @environment.Env::new(vars)
}
