///|
/// `login_home` is used only when HOME is not set.
pub struct Env {
  priv vars : Map[String, String]
  priv login_home : () -> String?
}

///|
pub fn Env::new(vars : Map[String, String], login_home~ : String) -> Env {
  { vars, login_home: () => Some(login_home), }
}

///|
/// An environment whose account home is looked up only if HOME is not set and a path needs it.
/// A lookup that finds nothing reads as an empty home; `Env::home_known` tells the caller before it relies on one.
pub fn Env::deferred_home(
  vars : Map[String, String],
  login_home : () -> String?,
) -> Env {
  { vars, login_home, }
}

///|
/// False only when HOME is not set and the account has no home to fall back to.
pub fn Env::home_known(self : Env) -> Bool {
  self.vars.contains("HOME") || (self.login_home)() is Some(_)
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
  match self.vars.get("HOME") {
    Some(home) => home
    None => (self.login_home)().unwrap_or("")
  }
}

///|
pub fn Env::codex_home(self : Env) -> String {
  absolute_or(self.get("CODEX_HOME"), @path.join([self.home(), ".codex"]))
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
/// Resolved as the t3 CLI resolves it.
pub fn Env::t3_home(self : Env) -> String {
  match self.get("T3CODE_HOME") {
    Some(set) if is_absolute(set) => set
    _ => @path.join([self.home(), ".t3"])
  }
}

///|
/// A relative directory is ignored, as the XDG spec has it, so the working directory never picks the templates or the state.
fn absolute_or(value : String?, fallback : String) -> String {
  match value {
    Some(set) if is_absolute(set) => set
    _ => fallback
  }
}

///|
fn is_absolute(path : String) -> Bool {
  @path.is_absolute(path)
}

///|
pub fn Env::worktrees(self : Env, app : App) -> String {
  match app {
    Codex => @path.join([self.codex_home(), "worktrees"])
    T3 => @path.join([self.t3_home(), "worktrees"])
  }
}

///|
pub const NAME : String = "harnexus-crew"
