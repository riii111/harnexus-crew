///|
pub struct Env {
  priv vars : Map[String, String]
}

///|
pub const NAME : String = "harnexus-crew"

///|
pub fn Env::new(vars : Map[String, String]) -> Env {
  { vars, }
}

///|
/// A variable that is set, even to the empty string.
pub fn Env::get(self : Env, name : String) -> String? {
  self.vars.get(name)
}

///|
/// A variable that is set to something; an empty value counts as not set.
pub fn Env::get_nonempty(self : Env, name : String) -> String? {
  match self.vars.get(name) {
    Some("") => None
    other => other
  }
}

///|
pub fn Env::to_map(self : Env) -> Map[String, String] {
  let copy = Map([])
  for name, value in self.vars {
    copy[name] = value
  }
  copy
}

///|
/// An empty HOME is used as it is, so paths below it become relative.
pub fn Env::home(self : Env) -> String {
  self.vars.get("HOME").unwrap_or("")
}

///|
pub fn Env::config_home(self : Env) -> String {
  @path.join([
    absolute_or(
      self.get("XDG_CONFIG_HOME"),
      @path.join([self.home(), ".config"]),
    ),
    "harnexus",
  ])
}

///|
pub fn Env::state_root(self : Env) -> String {
  @path.join([
    absolute_or(
      self.get("XDG_STATE_HOME"),
      @path.join([self.home(), ".local/state"]),
    ),
    "harnexus-crew",
  ])
}

///|
pub fn Env::t3_home(self : Env) -> String {
  match self.get("T3CODE_HOME") {
    Some(set) if is_absolute(set) => set
    _ => @path.join([self.home(), ".t3"])
  }
}

///|
pub fn Env::worktrees(self : Env, app : App) -> String {
  match app {
    Codex => @path.join([self.codex_home(), "worktrees"])
    T3 => @path.join([self.t3_home(), "worktrees"])
  }
}

///|
fn Env::codex_home(self : Env) -> String {
  absolute_or(self.get("CODEX_HOME"), @path.join([self.home(), ".codex"]))
}

///|
fn absolute_or(value : String?, fallback : String) -> String {
  match value {
    Some(set) if is_absolute(set) => set
    // Relative paths would let the working directory choose the storage location, so ignore them as XDG specifies.
    _ => fallback
  }
}

///|
fn is_absolute(path : String) -> Bool {
  @path.is_absolute(path)
}
