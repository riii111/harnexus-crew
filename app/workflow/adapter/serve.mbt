///|
pub async fn serve(
  env : @environment.Env,
  adapter_id : String,
  read_line~ : async () -> String? noraise,
  send~ : async (String) -> Unit noraise,
  log~ : async (Array[(String, Json)]) -> Unit noraise,
) -> Unit {
  let parts = build_parts(env)
  let adapter = Adapter::new({
    adapter_id,
    send,
    store: parts.store,
    observations: parts.observations,
    locks: parts.locks,
    review_home: @path.join([env.home(), "review-home"]),
    log,
  })

  @async.with_task_group(outer => {
    outer.spawn_bg(() => adapter.run_jobs())

    @async.with_task_group(handlers => {
      while true {
        guard read_line() is Some(line) else { break }

        match adapter.accept(line) {
          Handled => ()
          Later(work) => handlers.spawn_bg(() => work())
        }
      }

      adapter.close_input()
    })

    adapter.finish()
  })
}

///|
priv struct Parts {
  store : ReviewStore
  observations : Observations
  locks : String
}

///|
fn build_parts(env : @environment.Env) -> Parts raise @failure.TaskFailed {
  let observations = Observations::new(observation_root(env))
  let locks = observations.locks_directory()

  {
    store: ReviewStore::new(resolve_reviews_directory(env), locks),
    observations,
    locks,
  }
}
