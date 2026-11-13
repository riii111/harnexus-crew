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
test "resolve starts from the given directory unless a part is absolute" {
  inspect(resolve(cwd="/work/dir", ["../x"]), content="/work/x")
  inspect(resolve(cwd="/work/dir", ["/a", "/b", "c"]), content="/b/c")
  inspect(resolve(cwd="/work/dir", ["a/../.."]), content="/work")
  inspect(resolve(cwd="/work/dir", [""]), content="/work/dir")
}
