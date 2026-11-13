///|
fn refusal(reply : Bytes) -> String {
  try {
    ignore(read_destinations(reply))
    "accepted"
  } catch {
    @failure.TaskFailed(message) => message
  }
}

///|
test "offsets are UTF-16 positions of the target in the template" {
  let template = "日本 [a](x.md) 😀 [b](y.md)"
  let found = links(template, nonce="n")
  inspect(
    found.map(fn(link) { "\{link.start}-\{link.end}" }).join(","),
    content="7-11,20-24",
  )
  inspect(template[found[1].start:found[1].end], content="y.md")
}

///|
test "comments are blanked with the newlines kept" {
  inspect(blank_comments("a<!--x\ny-->b"), content="a     \n    b")
  inspect(blank_comments("a<!--x"), content="a<!--x")
  inspect(blank_comments("<!-->x-->"), content="         ")
}

///|
test "a parser failure is never read as a template with no links" {
  inspect(refusal(b"\x01"), content="the Markdown parser (md4c) failed")
  inspect(
    refusal(b"\x02"),
    content="the Markdown parser (md4c) ran out of memory",
  )
  inspect(
    refusal(b"\x00A\x05\x00\x00\x00ab"),
    content="the Markdown parser (md4c) returned a truncated record",
  )
}

///|
test "records carry their length, so a destination may hold any byte" {
  let found = read_destinations(
    b"\x00A\x03\x00\x00\x00a\x00bI\x01\x00\x00\x00c",
  )
  inspect(
    found.map(fn(text) { text.length().to_string() }).join(","),
    content="3,1",
  )
}
