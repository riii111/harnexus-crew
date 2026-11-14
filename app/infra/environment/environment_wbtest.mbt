///|
fn env_of(pairs : Array[(String, String)]) -> Env {
  let vars = Map([])
  for pair in pairs {
    let (name, value) = pair
    vars[name] = value
  }
  Env::new(vars)
}

///|
fn detected(pairs : Array[(String, String)]) -> String {
  try {
    match detect(env_of(pairs)) {
      Settled(found) => found.to_json().stringify()
      AskSocket(path) => "ask \{path}"
      NothingToAsk => "nothing to ask"
    }
  } catch {
    @failure.TaskFailed(message) => "refused: \{message}"
  }
}

///|
test "an explicit local names the app, an explicit cloud names the Cloud or none" {
  inspect(
    detected([("HARNEXUS_EXECUTION_ENV", "local")]),
    content="{\"environment\":\"local\",\"source\":\"explicit\",\"app\":\"codex\",\"note\":\"set by HARNEXUS_EXECUTION_ENV\"}",
  )
  inspect(
    detected([
      ("HARNEXUS_EXECUTION_ENV", "local"),
      ("CODEX_ENVIRONMENT_ID", "e"),
    ]),
    content="{\"environment\":\"local\",\"source\":\"explicit\",\"app\":\"codex\",\"note\":\"set by HARNEXUS_EXECUTION_ENV\"}",
  )
  inspect(
    detected([("HARNEXUS_EXECUTION_ENV", "local"), ("T3CODE_THREAD_ID", "t")]),
    content="{\"environment\":\"local\",\"source\":\"explicit\",\"app\":\"t3\",\"note\":\"set by HARNEXUS_EXECUTION_ENV\"}",
  )
  inspect(
    detected([("HARNEXUS_EXECUTION_ENV", "cloud")]),
    content="{\"environment\":\"cloud\",\"source\":\"explicit\",\"host\":null,\"note\":\"set by HARNEXUS_EXECUTION_ENV\"}",
  )
  inspect(
    detected([
      ("HARNEXUS_EXECUTION_ENV", "cloud"),
      ("CODEX_ENVIRONMENT_ID", "e"),
      ("CLAUDE_CODE_REMOTE", "true"),
    ]),
    content="{\"environment\":\"cloud\",\"source\":\"explicit\",\"host\":\"codex\",\"note\":\"set by HARNEXUS_EXECUTION_ENV\"}",
  )
  inspect(
    detected([
      ("HARNEXUS_EXECUTION_ENV", "cloud"),
      ("CLAUDE_CODE_REMOTE", "true"),
    ]),
    content="{\"environment\":\"cloud\",\"source\":\"explicit\",\"host\":\"claude\",\"note\":\"set by HARNEXUS_EXECUTION_ENV\"}",
  )
}

///|
test "a Cloud variable names the Cloud without printing its value" {
  inspect(
    detected([("CODEX_ENVIRONMENT_ID", "secret")]),
    content="{\"environment\":\"cloud\",\"source\":\"CODEX_ENVIRONMENT_ID\",\"host\":\"codex\",\"note\":\"CODEX_ENVIRONMENT_ID is an observed variable of Codex Cloud tasks, not a documented guarantee; set HARNEXUS_EXECUTION_ENV=cloud|local to decide explicitly\"}",
  )
  inspect(
    detected([("CLAUDE_CODE_REMOTE", "true")]),
    content="{\"environment\":\"cloud\",\"source\":\"CLAUDE_CODE_REMOTE\",\"host\":\"claude\",\"note\":\"CLAUDE_CODE_REMOTE is set in Claude Code cloud sessions\"}",
  )
  inspect(
    detected([("CODEX_ENVIRONMENT_ID", "e"), ("CLAUDE_CODE_REMOTE", "true")]),
    content="{\"environment\":\"cloud\",\"source\":\"CODEX_ENVIRONMENT_ID\",\"host\":\"codex\",\"note\":\"CODEX_ENVIRONMENT_ID is an observed variable of Codex Cloud tasks, not a documented guarantee; set HARNEXUS_EXECUTION_ENV=cloud|local to decide explicitly\"}",
  )
}

///|
test "T3 Code is local without asking the socket" {
  inspect(
    detected([("T3CODE_THREAD_ID", "t")]),
    content="{\"environment\":\"local\",\"source\":\"T3CODE_THREAD_ID\",\"app\":\"t3\",\"note\":\"T3 Code sets T3CODE_THREAD_ID for its agents and the commands they run\"}",
  )
}

///|
test "only a socket that answers makes the command local" {
  inspect(
    detected([("HOME", "/h")]),
    content="ask /h/.local/state/harnexus/call.sock",
  )
  inspect(
    detected([("HARNEXUS_CALL_SOCKET", "/s/c.sock")]),
    content="ask /s/c.sock",
  )
  inspect(detected([("HARNEXUS_CALL_SOCKET", "rel")]), content="nothing to ask")
  inspect(
    detected([
      ("HARNEXUS_EXECUTION_ENV", ""),
      ("CODEX_ENVIRONMENT_ID", ""),
      ("T3CODE_THREAD_ID", ""),
      ("HOME", "/h"),
    ]),
    content="ask /h/.local/state/harnexus/call.sock",
  )
}

///|
test "a value other than cloud or local is refused" {
  inspect(
    detected([("HARNEXUS_EXECUTION_ENV", "x")]),
    content="refused: HARNEXUS_EXECUTION_ENV must be cloud or local, not \"x\"",
  )
  inspect(
    detected([("CLAUDE_CODE_REMOTE", "1"), ("HOME", "/h")]),
    content="ask /h/.local/state/harnexus/call.sock",
  )
}

///|
test "the T3 variable decides the app first" {
  inspect(
    app_of(env_of([("T3CODE_THREAD_ID", "t"), ("CODEX_THREAD_ID", "c")])).name(),
    content="t3",
  )
  inspect(app_of(env_of([("T3CODE_THREAD_ID", "")])).name(), content="codex")
  inspect(thread_variable(T3), content="T3CODE_THREAD_ID")
  inspect(thread_variable(Codex), content="CODEX_THREAD_ID")
}

///|
test "directories ignore a relative setting and fall back below HOME" {
  let env = env_of([
    ("HOME", "/h/"),
    ("XDG_CONFIG_HOME", "rel"),
    ("XDG_STATE_HOME", "/xs//z/"),
    ("CODEX_HOME", "/cx/./a"),
    ("T3CODE_HOME", "t3"),
  ])
  inspect(env.config_home(), content="/h/.config/harnexus")
  inspect(env.state_root(), content="/xs/z/harnexus-crew")
  inspect(env.codex_home(), content="/cx/./a")
  inspect(env.t3_home(), content="/h/.t3")
}

///|
test "an empty HOME is used as it is" {
  inspect(env_of([("HOME", "")]).home(), content="")
  inspect(env_of([("HOME", "")]).config_home(), content=".config/harnexus")
}

///|
test "the call socket sits beside the harnexus state unless a path is given" {
  let state = env_of([
    ("HOME", "/h"),
    ("HARNEXUS_STATE_PATH", "/a/../b/threads.json"),
  ])
  inspect(resolve_harnexus_state_path(state), content="/a/../b/threads.json")
  inspect(resolve_call_socket_path(state), content="/b/call.sock")
  inspect(
    resolve_call_socket_path(env_of([("HARNEXUS_CALL_SOCKET", "/s/c.sock")])),
    content="/s/c.sock",
  )
  inspect(
    resolve_caller_socket(env_of([("HARNEXUS_CALL_SOCKET", "off")])) is None,
    content="true",
  )
  inspect(
    resolve_call_socket_path(
      env_of([("HARNEXUS_CALL_SOCKET", "off"), ("HOME", "/h")]),
    ),
    content="/h/.local/state/harnexus/call.sock",
  )
}

///|
test "a relative socket or state path is refused" {
  let socket = try {
    resolve_call_socket_path(env_of([("HARNEXUS_CALL_SOCKET", "rel")]))
    |> ignore
    "accepted"
  } catch {
    @failure.TaskFailed(message) => message
  }
  inspect(
    socket,
    content="HARNEXUS_CALL_SOCKET must be on, off or an absolute path",
  )
  let state = try {
    resolve_harnexus_state_path(env_of([("HARNEXUS_STATE_PATH", "rel")]))
    |> ignore
    "accepted"
  } catch {
    @failure.TaskFailed(message) => message
  }
  inspect(state, content="HARNEXUS_STATE_PATH must be an absolute path")
}
