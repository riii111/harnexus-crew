///|
fn read(text : String) -> String {
  try {
    let config = TemplateConfig::from_json("/c/task.json", @jsonio.parse(text))
    "ok worker=\{config.worker.unwrap_or("-")} reviewer=\{config.reviewer.unwrap_or("-")}"
  } catch {
    @failure.TaskFailed(message) => message
    _ => "not JSON"
  }
}

///|
test "absolute template paths are accepted, and either may be left out" {
  inspect(read("{\"templates\":{}}"), content="ok worker=- reviewer=-")
  inspect(
    read("{\"templates\":{\"worker\":\"/w\",\"reviewer\":\"/r\"}}"),
    content="ok worker=/w reviewer=/r",
  )
}

///|
test "a config that is not an object with templates is refused" {
  inspect(
    read("{}"),
    content="/c/task.json is invalid: templates must be an object",
  )
  inspect(read("[]"), content="/c/task.json is invalid: it must be an object")
  inspect(
    read("{\"templates\":\"x\"}"),
    content="/c/task.json is invalid: templates must be an object",
  )
}

///|
test "a template path must be an absolute string" {
  inspect(
    read("{\"templates\":{\"worker\":\"w\"}}"),
    content="/c/task.json is invalid: templates.worker must be an absolute path",
  )
  inspect(
    read("{\"templates\":{\"reviewer\":null}}"),
    content="/c/task.json is invalid: templates.reviewer must be an absolute path",
  )
}

///|
test "unknown keys are refused at both levels" {
  inspect(
    read("{\"templates\":{},\"other\":1}"),
    content="/c/task.json is invalid: unknown field \"other\"",
  )
  inspect(
    read("{\"templates\":{\"x\":1}}"),
    content="/c/task.json is invalid: unknown field \"templates.x\"",
  )
}

///|
test "the config sits in harnexus's config directory" {
  let env = @environment.Env::new({ "XDG_CONFIG_HOME": "/xc/../y" })
  inspect(template_config_path(env), content="/y/harnexus/task.json")
}
