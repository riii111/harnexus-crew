///|
#borrow(out)
extern "C" fn login_home_raw(out : FixedArray[Byte], cap : Int32) -> Int32 = "harnexus_login_home"

///|
/// The home directory could not be found for a process whose HOME is not set.
pub suberror HomeNotFound {
  HomeNotFound
}

///|
/// The environment this process was started with.
/// The account's home directory is looked up only when HOME is not set.
pub fn process_env() -> @environment.Env raise {
  let vars = @env.get_env_vars()
  let login_home = if vars.contains("HOME") { "" } else { login_home() }
  @environment.Env::new(vars, login_home~)
}

///|
fn login_home() -> String raise HomeNotFound {
  let out : FixedArray[Byte] = FixedArray::make(4096, b'\x00')
  let len = login_home_raw(out, 4096)
  if len <= 0 {
    raise HomeNotFound
  }
  @utf8.decode_lossy(Bytes::from_array(out[:len]))
}
