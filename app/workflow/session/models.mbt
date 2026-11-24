///|
priv enum ModelRole {
  WorkerModel
  ReviewerModel
}

///|
priv struct ModelSettings {
  model : String
  thinking : String
}

///|
priv struct TaskModels {
  worker : ModelSettings
  reviewer : ModelSettings
}

///|
let built_in_models : TaskModels = {
  worker: { model: "gpt-6.1-terra", thinking: "xhigh", },
  reviewer: { model: "gpt-6.2-sol", thinking: "high", },
}

///|
pub fn check_model_settings(
  env : @environment.Env,
) -> Unit raise @failure.TaskFailed {
  ignore(read_models(env))
}

///|
fn read_models(env : @environment.Env) -> TaskModels raise @failure.TaskFailed {
  let path = @path.join([env.config_home(), "models.json"])
  if !@store.path_exists(path) {
    return built_in_models
  }

  guard @store.read_regular_json(path) is Object(roles) else {
    @failure.fail("\{path} must contain an object")
  }

  for key, _ in roles {
    if key != "worker" && key != "reviewer" {
      @failure.fail("\{path}: unknown role \"\{key}\"")
    }
  }

  {
    worker: read_model_role(path, roles, "worker", built_in_models.worker),
    reviewer: read_model_role(path, roles, "reviewer", built_in_models.reviewer),
  }
}

///|
fn read_model_role(
  path : String,
  roles : Map[String, Json],
  role : String,
  fallback : ModelSettings,
) -> ModelSettings raise @failure.TaskFailed {
  guard roles.get(role) is Some(value) else { return fallback }
  guard value is Object(settings) else {
    @failure.fail("\{path}: \{role} must be an object")
  }

  for key, _ in settings {
    if key != "model" && key != "thinking" {
      @failure.fail("\{path}: unknown field \"\{role}.\{key}\"")
    }
  }

  let read_setting = fn(
    key : String,
    default_value : String,
  ) -> String raise @failure.TaskFailed {
    match settings.get(key) {
      None => default_value
      Some(String(value)) if !value.trim().is_empty() => value
      Some(_) =>
        @failure.fail("\{path}: \{role}.\{key} must be a non-empty string")
    }
  }

  {
    model: read_setting("model", fallback.model),
    thinking: read_setting("thinking", fallback.thinking),
  }
}

///|
fn apply_model_settings(
  ctx : Context,
  sent : Map[String, Json],
  role : ModelRole,
  model : String?,
  thinking : String?,
) -> Unit raise @failure.TaskFailed {
  let models = read_models(ctx.env)
  let settings = match role {
    WorkerModel => models.worker
    ReviewerModel => models.reviewer
  }

  sent["model"] = Json::string(@text.nonempty(model).unwrap_or(settings.model))
  match @text.nonempty(thinking) {
    Some(value) => sent["thinking"] = Json::string(value)
    None if ctx.host.supports_thinking =>
      sent["thinking"] = Json::string(settings.thinking)
    None => ()
  }
}
