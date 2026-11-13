///|
fn listed(points : Array[Int32]) -> String {
  points.map(fn(point) { point.to_string() }).join(",")
}

///|
test "code points join pairs" {
  inspect(listed(code_points("a\u{1F600}b")), content="97,128512,98")
}

///|
test "letters and numbers follow the pinned Bun" {
  let letters = [
    'a', 'Z', 'é', '漢', 'ǅ', 'ʰ', 'ª', '\u{1D49C}', '\u{20000}',
  ]
  for letter in letters {
    let code = letter.to_int()
    inspect(is_letter(code) && !is_number(code), content="true")
  }
  let numbers = ['²', '½', 'Ⅷ', '٣', '\u{1D7D8}']
  for number in numbers {
    let code = number.to_int()
    inspect(is_number(code) && !is_letter(code), content="true")
  }
  let neither = [
    '_', '#', '-', '\u{D7FF}', '\u{1F600}', '\u{E0001}', '\u{10FFFF}',
  ]
  for other in neither {
    let code = other.to_int()
    inspect(is_letter(code) || is_number(code), content="false")
  }
  inspect(is_letter(0xD800) || is_number(0xD800), content="false")
}

///|
test "space is Python's isspace, not JS whitespace" {
  inspect(is_space(0x85) && is_space(0x1F) && is_space(0x3000), content="true")
  inspect(
    is_space(0xFEFF) || is_space(0x200B) || is_space(0x180E),
    content="false",
  )
  inspect(has_space("a b"), content="true")
  inspect(has_space("ab"), content="false")
  inspect(has_space("a\u{85}b"), content="true")
  inspect(is_blank(""), content="true")
  inspect(is_blank(" \t\u{3000}"), content="true")
  inspect(is_blank(" x "), content="false")
}

///|
test "trim removes JS whitespace, which has U+FEFF and lacks U+0085" {
  inspect(js_trim("\u{FEFF} a b\n\u{3000}"), content="a b")
  inspect(js_trim("\u{85}a\u{1F}"), content="\u{85}a\u{1F}")
  inspect(js_trim("   "), content="")
  inspect(js_trim("a"), content="a")
  inspect(js_trim_end(" a b \u{feff}\u{b}"), content=" a b")
  inspect(
    js_trim_end("a\u{200b}\u{180e}\u{85}"),
    content="a\u{200b}\u{180e}\u{85}",
  )
}

///|
test "a JS whitespace character anywhere in the text is found" {
  inspect(has_js_whitespace("a\u{FEFF}b"), content="true")
  inspect(has_js_whitespace("a\u{3000}"), content="true")
  inspect(has_js_whitespace("a\u{85}b\u{1F}"), content="false")
  inspect(has_js_whitespace(""), content="false")
}

///|
test "strings compare by code unit as JS sorts them" {
  inspect(compare_utf16("\u{1F600}", "\u{FF5E}"), content="-1")
  inspect(compare_utf16("ab", "a"), content="1")
  inspect(compare_utf16("a", "a"), content="0")
}
