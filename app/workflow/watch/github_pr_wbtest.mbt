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
test "a URL that is not a github.com pull request is not linkable" {
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
test "the number is read from a linkable URL" {
  for
    url in [
      "https://github.com/o/r/pull/12", "https://github.com/o/r/pull/12/files#x",
    ] {
    assert_eq(github_pr_number(url), Some("12"), msg=url)
  }
}

///|
test "no number is read from a URL that is not linkable" {
  assert_eq(github_pr_number("https://github.com/o/r/pull/12"), Some("12"))
  assert_eq(github_pr_number("https://github.com/o/r/pull/12x"), None)
}
