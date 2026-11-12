///|
test "a github.com pull request URL is linkable, with or without what a browser appends" {
  for
    url in [
      "https://github.com/riii111/harnexus-crew/pull/20", "https://github.com/a/b/pull/1",
      "https://github.com/A_b.c-d/E.f_g-h/pull/987654321", "https://github.com/o/r/pull/7/files",
      "https://github.com/o/r/pull/7/", "https://github.com/o/r/pull/7?diff=split",
      "https://github.com/o/r/pull/7#issuecomment-1", "https://github.com/o/r/pull/7/files#diff-abc?x=y",
      "https://github.com/o/r/pull/7/日本語", "https://github.com/./-/pull/7",
    ] {
    assert_true(is_github_pr(url), msg=url)
  }
}

///|
test "anything else is named but never linked" {
  for
    url in [
      "", "#20", "20", "http://github.com/o/r/pull/7", "https://github.com/o/r/pull/0",
      "https://github.com/o/r/pull/07", "https://github.com/o/r/pull/7x", "https://github.com/o/r/pull/7 ",
      "https://github.com/o/r/pull/7/a b", "https://github.com/o/r/pull/7?\u{A0}",
      "https://github.com/o/r/pull/7\u{FEFF}", "https://github.com/o/r/pull/7\n",
      "https://github.com/o/r/pull/", "https://github.com/o/r/pull", "https://github.com/o/r/pulls/7",
      "https://github.com/o/pull/7", "https://github.com//r/pull/7", "https://github.com/o//pull/7",
      "https://github.com/o/r/issues/7", "https://github.com/o/r/pull/-7", "https://github.com/日本/r/pull/7",
      "https://github.com/o r/x/pull/7", "https://www.github.com/o/r/pull/7", "https://example.com/o/r/pull/7",
      " https://github.com/o/r/pull/7", "https://github.com/o/r/pull/7\u{2028}x",
    ] {
    assert_false(is_github_pr(url), msg=url)
  }
}

///|
test "the whitespace after a PR number is JavaScript's, which trim also removes" {
  for unit in 0..<0x10000 {
    if unit >= 0xD800 && unit <= 0xDFFF {
      continue
    }
    let text = unit.unsafe_to_char().to_string()
    assert_eq(is_js_space(unit), @text.js_trim(text) == "", msg="U+\{unit}")
  }
}
