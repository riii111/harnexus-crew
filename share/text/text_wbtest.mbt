///|
test "letters and digits are ASCII only" {
  for unit in ['a', 'z', 'A', 'Z', '0', '9'] {
    assert_true(is_ascii_alphanumeric(unit.to_int()))
  }

  for unit in ['_', '-', '/', '@', '[', '`', '{', 'é', '²', '漢'] {
    assert_false(is_ascii_alphanumeric(unit.to_int()))
  }
}

///|
test "is_space accepts JS whitespace including U+FEFF and rejects U+0085" {
  for unit in [0x20, 0x09, 0xA0, 0x3000, 0xFEFF] {
    assert_true(is_space(unit), msg="\{unit}")
  }

  for unit in [0x61, 0x85, 0x1F, 0x200B] {
    assert_false(is_space(unit), msg="\{unit}")
  }
}

///|
test "has_space is true when any unit is JS whitespace" {
  inspect(has_space("a b"), content="true")
  inspect(has_space("a\u{FEFF}b"), content="true")
  inspect(has_space("ab"), content="false")
}

///|
test "is_blank is true for empty and all-whitespace text" {
  inspect(is_blank(""), content="true")
  inspect(is_blank(" \t\u{3000}"), content="true")
  inspect(is_blank(" x "), content="false")
}

///|
test "js_trim strips JS whitespace at both ends only" {
  inspect(js_trim("\u{FEFF} a b\n\u{3000}"), content="a b")
  inspect(js_trim("\u{85}a\u{1F}"), content="\u{85}a\u{1F}")
  inspect(js_trim(" \u{1F600} "), content="\u{1F600}")
  inspect(js_trim("   "), content="")
  inspect(js_trim("a"), content="a")
}

///|
test "js_trim_end strips JS whitespace at the end only" {
  inspect(js_trim_end(" a b \u{feff}\u{b}"), content=" a b")
  inspect(
    js_trim_end("a\u{200b}\u{180e}\u{85}"),
    content="a\u{200b}\u{180e}\u{85}",
  )
}

///|
test "an excerpt is the trimmed text up to 500 UTF-16 units" {
  assert_eq(excerpt("  boom \n\n"), "boom")
  assert_eq(excerpt(""), "")
  assert_eq(excerpt("あ".repeat(500)), "あ".repeat(500))
  assert_eq(excerpt("あ".repeat(600)), "あ".repeat(500))
}

///|
test "an excerpt cut through a surrogate pair ends in U+FFFD instead of half a character" {
  assert_eq(excerpt("a".repeat(498) + "😀tail"), "a".repeat(498) + "😀")
  assert_eq(excerpt("a".repeat(499) + "😀tail"), "a".repeat(499) + "\u{FFFD}")
}
