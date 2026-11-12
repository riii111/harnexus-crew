///|
test "stringify_indented matches JSON.stringify with one space of indent" {
  let cases = [
    ("{}", "{}"),
    ("[]", "[]"),
    ("{\"a\":[]}", "{\n \"a\": []\n}"),
    ("{\"a\":{}}", "{\n \"a\": {}\n}"),
    ("[[],{}]", "[\n [],\n {}\n]"),
    (
      "{\"a,b\":\"x:y[{\\\"\",\"k\":[1,[2,{\"z\":null}],true],\"e\\\\\":\"\\\\\\\"\"}",
      "{\n \"a,b\": \"x:y[{\\\"\",\n \"k\": [\n  1,\n  [\n   2,\n   {\n    \"z\": null\n   }\n  ],\n  true\n ],\n \"e\\\\\": \"\\\\\\\"\"\n}",
    ),
    ("\"s\"", "\"s\""),
    ("5", "5"),
    ("null", "null"),
    ("[{\"a\":1,\"b\":[]}]", "[\n {\n  \"a\": 1,\n  \"b\": []\n }\n]"),
    ("{\"é\":\"ü\",\"😀\":1}", "{\n \"é\": \"ü\",\n \"😀\": 1\n}"),
    (
      "{\"2\":\"a\",\"1\":\"b\",\"x\":\"c\"}", "{\n \"1\": \"b\",\n \"2\": \"a\",\n \"x\": \"c\"\n}",
    ),
  ]
  for case in cases {
    assert_eq(stringify_indented(@jsonio.parse(case.0)), case.1)
  }
}
