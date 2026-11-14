///|
test "a field is filled" {
  inspect(outcome("Work on {task_id}", fields), content="Work on T-1")
}

///|
test "a doubled brace is one brace" {
  inspect(outcome("{{literal}}", fields), content="{literal}")
}

///|
test "an unknown field is refused" {
  let unknown = [("{unknown}", "unknown"), ("{a}}", "a"), ("{}", "")]
  for case in unknown {
    assert_eq(
      outcome(case.0, fields),
      "refused: unknown template field {\{case.1}}",
      msg=case.0,
    )
  }
}

///|
test "a single opening brace is refused" {
  for template in ["a { b", "{task_id"] {
    assert_eq(
      outcome(template, fields),
      "refused: single '{' in template",
      msg=template,
    )
  }
}

///|
test "a single closing brace is refused" {
  for template in ["a } b", "{{a}"] {
    assert_eq(
      outcome(template, fields),
      "refused: single '}' in template",
      msg=template,
    )
  }
}

///|
test "the first problem in a template is the one reported" {
  inspect(
    outcome("{checkout} {nope} {", fields),
    content="refused: unknown template field {nope}",
  )
}

///|
test "a value can be refused at the place it goes" {
  inspect(
    outcome("x/{task_id}/y", fields, refuse=refuse_unless_name),
    content="x/T-1/y",
  )
  inspect(
    outcome("x/{checkout}", fields, refuse=refuse_unless_name),
    content="refused: {checkout} may hold only letters, digits, _ and - inside a link target",
  )
}

///|
test "a name may hold only ASCII letters and digits, _ and -" {
  assert_eq(refuse_unless_name("Name_2-x"), None)

  for value in ["名前", "", "a.b"] {
    assert_eq(
      refuse_unless_name(value),
      Some("may hold only letters, digits, _ and - inside a link target"),
      msg=value,
    )
  }
}

///|
test "braces are escaped for a later fill" {
  inspect(escape_braces("a{b}c"), content="a{{b}}c")
  inspect(outcome(escape_braces("a{b}c"), fields), content="a{b}c")
}

///|
fn outcome(
  template : String,
  fields : Map[String, String],
  refuse~ : (String) -> String? = fn(_) { None },
) -> String {
  format(template, fields, refuse~) catch {
    @failure.TaskFailed(message) => "refused: \{message}"
  }
}

///|
let fields : Map[String, String] = {
  "task_id": "T-1",
  "pr_url": "https://x/1",
  "checkout": "/p q",
}
