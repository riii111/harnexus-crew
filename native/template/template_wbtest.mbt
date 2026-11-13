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

///|
test "a field is filled and a doubled brace is one brace" {
  inspect(
    outcome("Work on {task_id} {{literal}}", fields),
    content="Work on T-1 {literal}",
  )
}

///|
test "an unknown field or a single brace is refused at the first problem" {
  inspect(
    outcome("{unknown}", fields),
    content="refused: unknown template field {unknown}",
  )
  inspect(outcome("a { b", fields), content="refused: single '{' in template")
  inspect(outcome("a } b", fields), content="refused: single '}' in template")
  inspect(outcome("{{a}", fields), content="refused: single '}' in template")
  inspect(
    outcome("{a}}", fields),
    content="refused: unknown template field {a}",
  )
  inspect(outcome("{}", fields), content="refused: unknown template field {}")
  inspect(
    outcome("{task_id", fields),
    content="refused: single '{' in template",
  )
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
  inspect(refuse_unless_name("Name_2-x") is None, content="true")
  inspect(refuse_unless_name("名前") is Some(_), content="true")
  inspect(refuse_unless_name("") is Some(_), content="true")
  inspect(refuse_unless_name("a.b") is Some(_), content="true")
}

///|
test "braces are escaped for a later fill" {
  inspect(escape_braces("a{b}c"), content="a{{b}}c")
  inspect(outcome(escape_braces("a{b}c"), fields), content="a{b}c")
}
