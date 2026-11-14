///|
async fn main {
  @run.finish(@cli.run(@env.args()[1:], () => @environment.read_process_env()))
}
