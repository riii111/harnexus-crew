///|
test "write_text reports EBADF with the descriptor on a closed descriptor" {
  let outcome = try {
    write_text(-1, "x")
    "accepted"
  } catch {
    WriteFailed(fd~, errno~) => "fd=\{fd} errno=\{errno}"
  }
  inspect(outcome, content="fd=-1 errno=9")
}
