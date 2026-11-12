///|
fn raws(template : String) -> String raise @failure.TaskFailed {
  links(template, nonce="n").map(fn(candidate) { candidate.raw }).join("|")
}

///|
test "candidates stop at the first closing parenthesis on their line" {
  inspect(raws("[a](x.md) and [b](y.md)"), content="x.md|y.md")
  inspect(raws("![i](a.png) [b](c.md \"t\")"), content="a.png|c.md \"t\"")
  inspect(raws("[a](x\n.md)"), content="")
}

///|
test "a link target never spans a backtick, so code cannot take in the next link" {
  inspect(raws("`[a](b` [c](d.md)"), content="d.md")
  inspect(raws("`[a](b.md)` [c](d.md)"), content="d.md")
}

///|
test "candidates know their place among all of the template's candidates" {
  let found = links("[a](x.md)\n```\n[b](y.md)\n```\n[c](z.md)\n", nonce="n")
  inspect(
    found.map(fn(link) { link.index.to_string() }).join(","),
    content="0,2",
  )
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
test "a comment hides its links even when it spans blocks" {
  inspect(
    raws("<!--\n- [old](a.md)\n\n# Old\n[x](b.md)\n-->\n[new](c.md)"),
    content="c.md",
  )
  inspect(raws("<!-- [a](b.md)"), content="b.md")
}

///|
test "tags and indentation are read as text, where a link stays a link" {
  inspect(
    raws("<rules>\n[$s](a.md)\n</rules>\n\n    ![i](b.md)\n"),
    content="a.md|b.md",
  )
}

///|
test "a reference definition is not a candidate" {
  inspect(raws("[ref][r]\n\n[r]: ../linked.md\n"), content="")
}

///|
test "an empty target is a candidate" {
  inspect(raws("[a]()"), content="")
}

///|
test "comments are blanked with the newlines kept" {
  inspect(blank_comments("a<!--x\ny-->b"), content="a     \n    b")
  inspect(blank_comments("a<!--x"), content="a<!--x")
  inspect(blank_comments("<!-->x-->"), content="         ")
}

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
