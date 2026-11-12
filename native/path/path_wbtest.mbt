///|
test "join normalizes like Node's posix join" {
  inspect(join(["", "/.config"]), content="/.config")
  inspect(join(["", ".config"]), content=".config")
  inspect(join(["/Users/x/", ".codex"]), content="/Users/x/.codex")
  inspect(join(["/a/../b", ".codex"]), content="/b/.codex")
  inspect(join(["", ""]), content=".")
  inspect(join(["a", "b/"]), content="a/b/")
  inspect(join(["/..", "a"]), content="/a")
  inspect(join(["a", "..", "..", "b"]), content="../b")
  inspect(join(["/x//y", "./z"]), content="/x/y/z")
}

///|
test "dirname follows Node, including its odd results" {
  inspect(dirname("/"), content="/")
  inspect(dirname("//"), content="/")
  inspect(dirname("/a"), content="/")
  inspect(dirname("/a/"), content="/")
  inspect(dirname("a"), content=".")
  inspect(dirname("a/b/"), content="a")
  inspect(dirname(""), content=".")
  inspect(dirname("/a//b"), content="/a/")
}

///|
test "normalize keeps a trailing slash and the parents of a relative path" {
  inspect(normalize("a/../.."), content="..")
  inspect(normalize("/../a"), content="/a")
  inspect(normalize("./"), content="./")
  inspect(normalize("a/./b//c/"), content="a/b/c/")
  inspect(normalize(""), content=".")
}

///|
test "resolve starts from the given directory unless a part is absolute" {
  inspect(resolve(cwd="/work/dir", ["../x"]), content="/work/x")
  inspect(resolve(cwd="/work/dir", ["/a", "/b", "c"]), content="/b/c")
  inspect(resolve(cwd="/work/dir", ["a/../.."]), content="/work")
  inspect(resolve(cwd="/work/dir", [""]), content="/work/dir")
}
