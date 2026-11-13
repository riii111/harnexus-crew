///|
async fn main {
  @run.finish(@cli.run(@env.args()[1:], () => @environment.process_env()))
}
