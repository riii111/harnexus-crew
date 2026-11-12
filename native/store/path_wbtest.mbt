///|
test "dirname and basename follow path.dirname and path.basename of Node" {
  let cases = [
    ("a", ".", "a"),
    ("a/b", "a", "b"),
    ("/a", "/", "a"),
    ("/a/b", "/a", "b"),
    ("a/b/", "a", "b"),
    ("/", "/", ""),
    ("", ".", ""),
    (".", ".", "."),
    ("..", ".", ".."),
    ("a//b", "a/", "b"),
    ("/a/b//", "/a", "b"),
    ("a/b/c.json", "a/b", "c.json"),
    ("./x", ".", "x"),
    ("/a/./b/../c", "/a/./b/..", "c"),
    ("/..", "/", ".."),
    ("a/", ".", "a"),
  ]
  for case in cases {
    let (path, directory, name) = case
    assert_eq(dirname(path), directory)
    assert_eq(basename(path), name)
  }
}

///|
test "resolve_path folds dots, repeated separators and a trailing separator" {
  let cases = [
    ("/a/./b/../c", "/a/c"),
    ("//a//b/", "/a/b"),
    ("/..", "/"),
    ("/a/../..", "/"),
    ("/", "/"),
    ("/a/b/", "/a/b"),
    ("/a/../b/./c//", "/b/c"),
  ]
  for case in cases {
    assert_eq(resolve_path(case.0), case.1)
  }
}

///|
test "resolve_path takes a relative path from the working directory" {
  let working = @env.current_dir().unwrap()
  assert_eq(
    resolve_path("state/x.json"),
    resolve_path("\{working}/state/x.json"),
  )
  assert_eq(resolve_path("."), resolve_path(working))
}
