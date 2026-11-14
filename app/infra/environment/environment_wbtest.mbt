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
test "an explicit local names the app that runs it" {
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
}

///|
test "an explicit cloud names the Cloud host or none" {
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
}

///|
test "the Codex Cloud variable wins over the Claude Code one" {
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
test "an environment that declares nothing asks the call socket at its default path" {
  inspect(
    detected([("HOME", "/h")]),
    content="ask /h/.local/state/harnexus/call.sock",
  )
}

///|
test "an environment that declares nothing asks the call socket HARNEXUS_CALL_SOCKET gives" {
  inspect(
    detected([("HARNEXUS_CALL_SOCKET", "/s/c.sock")]),
    content="ask /s/c.sock",
  )
}

///|
test "an environment with a relative HARNEXUS_CALL_SOCKET has nothing to ask" {
  inspect(detected([("HARNEXUS_CALL_SOCKET", "rel")]), content="nothing to ask")
}

///|
test "empty declaring variables count as unset and the call socket is asked" {
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
}

///|
test "CLAUDE_CODE_REMOTE declares the Cloud only when it is true" {
  inspect(
    detected([("CLAUDE_CODE_REMOTE", "true"), ("HOME", "/h")]),
    content="{\"environment\":\"cloud\",\"source\":\"CLAUDE_CODE_REMOTE\",\"host\":\"claude\",\"note\":\"CLAUDE_CODE_REMOTE is set in Claude Code cloud sessions\"}",
  )
  inspect(
    detected([("CLAUDE_CODE_REMOTE", "1"), ("HOME", "/h")]),
    content="ask /h/.local/state/harnexus/call.sock",
  )
}

///|
test "the T3 variable decides the app before the Codex one" {
  inspect(
    app_of(env_of([("T3CODE_THREAD_ID", "t"), ("CODEX_THREAD_ID", "c")])).name(),
    content="t3",
  )
}

///|
test "an empty T3 variable leaves the app as Codex" {
  inspect(app_of(env_of([("T3CODE_THREAD_ID", "")])).name(), content="codex")
}

///|
test "each app has its own thread variable" {
  inspect(thread_variable(T3), content="T3CODE_THREAD_ID")
  inspect(thread_variable(Codex), content="CODEX_THREAD_ID")
}

///|
test "a relative directory setting is ignored and the directory falls back below HOME" {
  let env = env_of([
    ("HOME", "/h/"),
    ("XDG_CONFIG_HOME", "rel"),
    ("T3CODE_HOME", "t3"),
  ])

  inspect(env.config_home(), content="/h/.config/harnexus")
  inspect(env.t3_home(), content="/h/.t3")
}

///|
test "an absolute directory setting is used as the directory" {
  let env = env_of([("XDG_STATE_HOME", "/xs//z/"), ("CODEX_HOME", "/cx/./a")])

  inspect(env.state_root(), content="/xs/z/harnexus-crew")
  inspect(env.codex_home(), content="/cx/./a")
}

///|
test "an empty HOME is used as it is" {
  inspect(env_of([("HOME", "")]).home(), content="")
  inspect(env_of([("HOME", "")]).config_home(), content=".config/harnexus")
}

///|
test "the call socket sits beside the harnexus state path" {
  let state = env_of([
    ("HOME", "/h"),
    ("HARNEXUS_STATE_PATH", "/a/../b/threads.json"),
  ])
  inspect(resolve_harnexus_state_path(state), content="/a/../b/threads.json")

  inspect(resolve_call_socket_path(state), content="/b/call.sock")
}

///|
test "the call socket path is the one HARNEXUS_CALL_SOCKET gives" {
  inspect(
    resolve_call_socket_path(env_of([("HARNEXUS_CALL_SOCKET", "/s/c.sock")])),
    content="/s/c.sock",
  )
}

///|
test "a caller has no socket when HARNEXUS_CALL_SOCKET is off" {
  assert_eq(
    resolve_caller_socket(env_of([("HOME", "/h")])),
    Some("/h/.local/state/harnexus/call.sock"),
  )
  assert_eq(
    resolve_caller_socket(env_of([("HARNEXUS_CALL_SOCKET", "off")])),
    None,
  )
}

///|
test "the call socket path ignores an off setting and uses the default" {
  inspect(
    resolve_call_socket_path(
      env_of([("HARNEXUS_CALL_SOCKET", "off"), ("HOME", "/h")]),
    ),
    content="/h/.local/state/harnexus/call.sock",
  )
}

///|
test "a relative HARNEXUS_CALL_SOCKET is refused" {
  inspect(
    refusal(() => {
      ignore(
        resolve_call_socket_path(env_of([("HARNEXUS_CALL_SOCKET", "rel")])),
      )
    }),
    content="HARNEXUS_CALL_SOCKET must be on, off or an absolute path",
  )
}

///|
test "a relative HARNEXUS_STATE_PATH is refused" {
  inspect(
    refusal(() => {
      ignore(
        resolve_harnexus_state_path(env_of([("HARNEXUS_STATE_PATH", "rel")])),
      )
    }),
    content="HARNEXUS_STATE_PATH must be an absolute path",
  )
}

///|
fn refusal(work : () -> Unit raise @failure.TaskFailed) -> String {
  try {
    work()
    "accepted"
  } catch {
    @failure.TaskFailed(message) => message
  }
}
