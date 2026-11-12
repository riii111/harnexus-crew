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
    content="/c/task.json is invalid: ✖ Invalid input: expected object, received undefined\n  → at templates",
  )
  inspect(
    read("[]"),
    content="/c/task.json is invalid: ✖ Invalid input: expected object, received array",
  )
  inspect(
    read("null"),
    content="/c/task.json is invalid: ✖ Invalid input: expected object, received null",
  )
  inspect(
    read("{\"templates\":\"x\"}"),
    content="/c/task.json is invalid: ✖ Invalid input: expected object, received string\n  → at templates",
  )
}

///|
test "a template path must be an absolute string" {
  inspect(
    read("{\"templates\":{\"worker\":\"w\"}}"),
    content="/c/task.json is invalid: ✖ must be absolute\n  → at templates.worker",
  )
  inspect(
    read("{\"templates\":{\"worker\":null}}"),
    content="/c/task.json is invalid: ✖ Invalid input: expected string, received null\n  → at templates.worker",
  )
  inspect(
    read("{\"templates\":{\"worker\":1,\"reviewer\":\"r\"}}"),
    content="/c/task.json is invalid: ✖ Invalid input: expected string, received number\n  → at templates.worker\n✖ must be absolute\n  → at templates.reviewer",
  )
}

///|
test "unknown keys are refused at both levels, the outer one first" {
  inspect(
    read("{\"templates\":{\"x\":1,\"y\":2},\"other\":1}"),
    content="/c/task.json is invalid: ✖ Unrecognized key: \"other\"\n✖ Unrecognized keys: \"x\", \"y\"\n  → at templates",
  )
}

///|
test "the config sits in harnexus's config directory" {
  let env = @environment.Env::new(
    { "XDG_CONFIG_HOME": "/xc/../y" },
    login_home="/l",
  )
  inspect(template_config_path(env), content="/y/harnexus/task.json")
}
