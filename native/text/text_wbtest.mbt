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
test "space is JS whitespace, which has U+FEFF and lacks U+0085" {
  inspect(is_space(0xFEFF) && is_space(0x3000), content="true")
  inspect(is_space(0x85) || is_space(0x1F) || is_space(0x200B), content="false")
  inspect(has_space("a b"), content="true")
  inspect(has_space("ab"), content="false")
  inspect(has_space("a\u{FEFF}b"), content="true")
  inspect(is_blank(""), content="true")
  inspect(is_blank(" \t\u{3000}"), content="true")
  inspect(is_blank(" x "), content="false")
}

///|
test "trim removes the same whitespace" {
  inspect(js_trim("\u{FEFF} a b\n\u{3000}"), content="a b")
  inspect(js_trim("\u{85}a\u{1F}"), content="\u{85}a\u{1F}")
  inspect(js_trim(" \u{1F600} "), content="\u{1F600}")
  inspect(js_trim("   "), content="")
  inspect(js_trim("a"), content="a")
}

///|
test "strings compare by code unit as JS sorts them" {
  inspect(compare_utf16("\u{1F600}", "\u{FF5E}"), content="-1")
  inspect(compare_utf16("ab", "a"), content="1")
  inspect(compare_utf16("a", "a"), content="0")
}

///|
test "an excerpt is the trimmed text up to 500 UTF-16 units" {
  assert_eq(excerpt("  boom \n\n"), "boom")
  assert_eq(excerpt(""), "")
  assert_eq(excerpt("あ".repeat(500)), "あ".repeat(500))
  assert_eq(excerpt("あ".repeat(600)), "あ".repeat(500))
  assert_eq(excerpt("a".repeat(498) + "😀tail"), "a".repeat(498) + "😀")
  assert_eq(excerpt("a".repeat(499) + "😀tail"), "a".repeat(499) + "\u{FFFD}")
}
