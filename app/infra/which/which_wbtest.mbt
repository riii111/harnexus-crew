///|
test "the first runnable file on PATH wins" {
  let runnable = only(["/a/tool", "/b/tool"])

  assert_eq(
    find("tool", Some("/a:/b"), Some("/work"), runnable),
    Some("/a/tool"),
  )
}

///|
test "a file that cannot run is passed over" {
  let runnable = only(["/b/tool"])

  assert_eq(
    find("tool", Some("/a:/b:/c"), Some("/work"), runnable),
    Some("/b/tool"),
  )
}

///|
test "nothing is found when no PATH entry holds a runnable file" {
  let runnable = only(["/b/tool"])

  assert_eq(
    find("tool", Some("/a:/b"), Some("/work"), runnable),
    Some("/b/tool"),
  )

  assert_eq(find("tool", Some("/a:/c"), Some("/work"), runnable), None)
}

///|
test "an empty PATH entry is skipped" {
  let runnable = only(["/work/tool", "/b/tool"])

  assert_eq(find("tool", Some(":/b"), Some("/work"), runnable), Some("/b/tool"))
}

///|
test "a missing PATH finds nothing" {
  let runnable = only(["/work/tool", "/b/tool"])

  assert_eq(find("tool", Some("/b"), Some("/work"), runnable), Some("/b/tool"))

  assert_eq(find("tool", None, Some("/work"), runnable), None)
}

///|
test "an empty name finds nothing" {
  let runnable = only(["/b/", "/b/tool"])

  assert_eq(find("tool", Some("/b"), Some("/work"), runnable), Some("/b/tool"))

  assert_eq(find("", Some("/b"), Some("/work"), runnable), None)
}

///|
test "a relative entry is taken from the working directory and kept as written" {
  let runnable = only(["/work/./tool", "/work/rel/tool", "/work/../b/tool"])
  let entries = [
    (".", "/work/./tool"),
    ("rel/", "/work/rel/tool"),
    ("../b", "/work/../b/tool"),
  ]

  for entry in entries {
    assert_eq(
      find("tool", Some(entry.0), Some("/work"), runnable),
      Some(entry.1),
      msg=entry.0,
    )
  }
}

///|
test "a relative entry finds nothing without a working directory" {
  let runnable = only(["/work/rel/tool"])

  assert_eq(
    find("tool", Some("rel"), Some("/work"), runnable),
    Some("/work/rel/tool"),
  )

  assert_eq(find("tool", Some("rel"), None, runnable), None)
}

///|
test "a name with a slash is taken from the working directory instead of PATH" {
  let runnable = only(["/work/bin/tool", "/b/bin/tool"])

  for name in ["bin/tool", "./bin/tool"] {
    assert_eq(
      find(name, Some("/b"), Some("/work"), runnable),
      Some("/work/bin/tool"),
      msg=name,
    )
  }
}

///|
test "an absolute name is used as it is instead of searching PATH" {
  let runnable = only(["/abs/tool", "/b/abs/tool"])

  assert_eq(
    find("/abs/tool", Some("/b"), Some("/work"), runnable),
    Some("/abs/tool"),
  )
}

///|
test "a name with a slash finds nothing without a working directory" {
  let runnable = only(["/work/bin/tool"])

  assert_eq(
    find("bin/tool", Some("/b"), Some("/work"), runnable),
    Some("/work/bin/tool"),
  )

  assert_eq(find("bin/tool", Some("/b"), None, runnable), None)
}

///|
test "a directory that ends in a slash or is the root joins without doubling" {
  assert_eq(join_dir("/b/", "tool"), "/b/tool")
  assert_eq(join_dir("/", "tool"), "/tool")
}

///|
test "a file is runnable only when it is an executable regular file" {
  assert_true(is_runnable_file("/bin/sh"))

  for path in ["/bin", "/nonexistent/tool", "/etc/hosts"] {
    assert_false(is_runnable_file(path), msg=path)
  }
}

///|
test "in_env searches the PATH of the environment it is given" {
  let env = @environment.Env::new({ "PATH": "/nonexistent:/bin" })

  assert_eq(in_env(env)("sh"), Some("/bin/sh"))

  let empty = @environment.Env::new({})

  assert_eq(in_env(empty)("sh"), None)
}

///|
fn only(files : Array[String]) -> (String) -> Bool {
  path => files.contains(path)
}
