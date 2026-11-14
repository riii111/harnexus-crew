///|
test "write_text reports a closed descriptor" {
  let errno = try {
    write_text(-1, "x")
    0
  } catch {
    WriteFailed(errno~, ..) => errno
  }
  inspect(errno != 0, content="true")
}
