///|
async fn main {
  @run.finish(@cli.run(@env.args()[1:], @cli.process_env))
}
