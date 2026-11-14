///|
pub enum CloudHost {
  CodexCloud
  ClaudeCloud
}

///|
fn CloudHost::name(self : CloudHost) -> String {
  match self {
    CodexCloud => "codex"
    ClaudeCloud => "claude"
  }
}

///|
pub enum ExecutionEnvironment {
  Cloud
  Local
  Unknown
}

///|
fn ExecutionEnvironment::name(self : ExecutionEnvironment) -> String {
  match self {
    Cloud => "cloud"
    Local => "local"
    Unknown => "unknown"
  }
}

///|
/// `InCloud(None)` is an explicit cloud that names no host.
pub enum Runner {
  Unnamed
  InCloud(CloudHost?)
  OnMachine(App)
}

///|
const EXECUTION_VARIABLE : String = "HARNEXUS_EXECUTION_ENV"

///|
const CODEX_CLOUD_VARIABLE : String = "CODEX_ENVIRONMENT_ID"

///|
const CLAUDE_CLOUD_VARIABLE : String = "CLAUDE_CODE_REMOTE"

///|
/// Names a variable, never a value of the environment.
priv enum Source {
  Explicit
  CodexCloudVariable
  ClaudeCloudVariable
  T3ThreadVariable
  HarnexusSocket
  NoSource
}

///|
fn Source::name(self : Source) -> String {
  match self {
    Explicit => "explicit"
    CodexCloudVariable => CODEX_CLOUD_VARIABLE
    ClaudeCloudVariable => CLAUDE_CLOUD_VARIABLE
    T3ThreadVariable => T3_THREAD_VARIABLE
    HarnexusSocket => "harnexus-socket"
    NoSource => "none"
  }
}

///|
pub struct Detected {
  environment : ExecutionEnvironment
  priv source : Source
  runner : Runner
  priv note : String
}

///|
/// The members in the order the `environment` command prints them.
pub fn Detected::to_json(self : Detected) -> Json {
  let members : Array[(String, Json)] = [
    ("environment", Json::string(self.environment.name())),
    ("source", Json::string(self.source.name())),
  ]
  match self.runner {
    Unnamed => ()
    InCloud(host) =>
      members.push(
        (
          "host",
          match host {
            Some(named) => Json::string(named.name())
            None => Json::null()
          },
        ),
      )
    OnMachine(app) => members.push(("app", Json::string(app.name())))
  }
  members.push(("note", Json::string(self.note)))
  Json::object(Map::from_array(members))
}

///|
pub fn Detected::socket_accepted() -> Detected {
  {
    environment: Local,
    source: HarnexusSocket,
    runner: OnMachine(Codex),
    note: "the harnexus call socket accepted a connection",
  }
}

///|
pub fn Detected::undetermined() -> Detected {
  {
    environment: Unknown,
    source: NoSource,
    runner: Unnamed,
    note: "no \{EXECUTION_VARIABLE}, no \{CODEX_CLOUD_VARIABLE}, no \{CLAUDE_CLOUD_VARIABLE}=true and no harnexus call socket; set \{EXECUTION_VARIABLE}=cloud|local",
  }
}

///|
pub enum Detection {
  Settled(Detected)
  /// Carries the call socket whose acceptance of a connection makes the answer local.
  AskSocket(String)
  /// The socket setting names no usable path.
  NothingToAsk
}

///|
pub fn detect(env : Env) -> Detection raise @failure.TaskFailed {
  match parse_declared_environment(env) {
    Some(declared) => return Settled(declared)
    None => ()
  }
  if app_of(env) is T3 {
    return Settled({
      environment: Local,
      source: T3ThreadVariable,
      runner: OnMachine(T3),
      note: "T3 Code sets \{T3_THREAD_VARIABLE} for its agents and the commands they run",
    })
  }
  // A missing variable proves nothing, so local is claimed only once the socket answers.
  AskSocket(resolve_call_socket_path(env)) catch {
    @failure.TaskFailed(_) => NothingToAsk
  }
}

///|
/// None when the variables declare nothing.
pub fn parse_declared_environment(
  env : Env,
) -> Detected? raise @failure.TaskFailed {
  match env.get_nonempty(EXECUTION_VARIABLE) {
    Some("cloud") =>
      Some({
        environment: Cloud,
        source: Explicit,
        runner: InCloud(cloud_host_of(env)),
        note: "set by \{EXECUTION_VARIABLE}",
      })
    Some("local") =>
      Some({
        environment: Local,
        source: Explicit,
        runner: OnMachine(app_of(env)),
        note: "set by \{EXECUTION_VARIABLE}",
      })
    Some(other) =>
      @failure.fail(
        "\{EXECUTION_VARIABLE} must be cloud or local, not \"\{other}\"",
      )
    None =>
      match cloud_host_of(env) {
        Some(CodexCloud) =>
          Some({
            environment: Cloud,
            source: CodexCloudVariable,
            runner: InCloud(Some(CodexCloud)),
            note: "\{CODEX_CLOUD_VARIABLE} is an observed variable of Codex Cloud tasks, not a documented guarantee; set \{EXECUTION_VARIABLE}=cloud|local to decide explicitly",
          })
        Some(ClaudeCloud) =>
          Some({
            environment: Cloud,
            source: ClaudeCloudVariable,
            runner: InCloud(Some(ClaudeCloud)),
            note: "\{CLAUDE_CLOUD_VARIABLE} is set in Claude Code cloud sessions",
          })
        None => None
      }
  }
}

///|
fn cloud_host_of(env : Env) -> CloudHost? {
  match env.get_nonempty(CODEX_CLOUD_VARIABLE) {
    Some(_) => Some(CodexCloud)
    None =>
      match env.get(CLAUDE_CLOUD_VARIABLE) {
        Some("true") => Some(ClaudeCloud)
        _ => None
      }
  }
}
