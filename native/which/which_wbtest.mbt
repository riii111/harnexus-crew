///|
fn only(files : Array[String]) -> (String) -> Bool {
  path => files.contains(path)
}

///|
test "the first runnable file on PATH wins and a file that cannot run is passed over" {
  let runnable = only(["/b/tool"])
  assert_eq(
    find("tool", Some("/a:/b:/c"), Some("/work"), runnable),
    Some("/b/tool"),
  )
  assert_eq(find("tool", Some("/a:/c"), Some("/work"), runnable), None)
}

///|
test "an empty PATH entry is skipped and a missing PATH finds nothing" {
  let runnable = only(["/work/tool", "/b/tool"])
  assert_eq(find("tool", Some(":/b"), Some("/work"), runnable), Some("/b/tool"))
  assert_eq(find("tool", None, Some("/work"), runnable), None)
  assert_eq(find("", Some("/b"), Some("/work"), only([""])), None)
}

///|
test "a relative entry is taken from the working directory and kept as written" {
  let runnable = only(["/work/./tool", "/work/rel/tool", "/work/../b/tool"])
  assert_eq(
    find("tool", Some("."), Some("/work"), runnable),
    Some("/work/./tool"),
  )
  assert_eq(
    find("tool", Some("rel/"), Some("/work"), runnable),
    Some("/work/rel/tool"),
  )
  assert_eq(
    find("tool", Some("../b"), Some("/work"), runnable),
    Some("/work/../b/tool"),
  )
  assert_eq(find("tool", Some("rel"), None, runnable), None)
}

///|
test "a name with a slash is not searched on PATH" {
  let runnable = only(["/work/bin/tool", "/abs/tool", "/b/bin/tool"])
  assert_eq(
    find("bin/tool", Some("/b"), Some("/work"), runnable),
    Some("/work/bin/tool"),
  )
  assert_eq(
    find("./bin/tool", Some("/b"), Some("/work"), runnable),
    Some("/work/bin/tool"),
  )
  assert_eq(
    find("/abs/tool", Some("/b"), Some("/work"), runnable),
    Some("/abs/tool"),
  )
  assert_eq(find("bin/tool", Some("/b"), None, runnable), None)
}

///|
test "a directory that ends in a slash or is the root joins without doubling" {
  assert_eq(join_dir("/b/", "tool"), "/b/tool")
  assert_eq(join_dir("/", "tool"), "/tool")
}

///|
test "the real check accepts a runnable file and refuses a directory and a missing path" {
  assert_true(is_runnable_file("/bin/sh"))
  assert_false(is_runnable_file("/bin"))
  assert_false(is_runnable_file("/nonexistent/tool"))
  assert_false(is_runnable_file("/etc/hosts"))
}

///|
test "in_env searches the PATH of the environment it is given" {
  let env = @environment.Env::new(
    { "PATH": "/nonexistent:/bin" },
    login_home="/home/x",
  )
  assert_eq(in_env(env)("sh"), Some("/bin/sh"))
  let empty = @environment.Env::new({}, login_home="/home/x")
  assert_eq(in_env(empty)("sh"), None)
}
