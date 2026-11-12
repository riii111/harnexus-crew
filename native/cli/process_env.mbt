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
/// The account's home directory is looked up only when HOME is not set and a path needs it.
pub fn process_env() -> @environment.Env {
  @environment.Env::deferred_home(@env.get_env_vars(), login_home)
}

///|
fn login_home() -> String? {
  let out : FixedArray[Byte] = FixedArray::make(4096, b'\x00')
  let len = login_home_raw(out, 4096)
  if len <= 0 {
    return None
  }
  Some(@utf8.decode_lossy(Bytes::from_array(out[:len])))
}
