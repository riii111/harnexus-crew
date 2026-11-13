///|
/// A started command and the parent's ends of its pipes.
/// Once `reaped`, the pid is no longer this process's child and a signal to it alone would reach a stranger.
priv struct Child {
  pid : Int32
  new_session : Bool
  stdin : Fd
  stdout : Fd
  stderr : Fd
  mut reaped : Bool
  mut swept : Bool
}

///|
priv enum Exit {
  Code(Int32)
  Signaled(Int32)
}

///|
/// Why a command could not start: the errno, or an argument the OS cannot take.
priv suberror SpawnFailed {
  SpawnFailed(errno~ : Int32)
  InvalidArgument
}

///|
/// A descriptor the caller owns until a stream takes it.
/// `close_unless_taken` is the one place that closes it, so every path out releases it exactly once.
priv struct Fd {
  fd : Int32
  mut taken : Bool
}

///|
fn Fd::new(fd : Int32) -> Fd {
  { fd, taken: false, }
}

///|
/// Ownership passes to the stream at the call, even if creating it fails.
async fn Fd::stream(self : Fd) -> @raw_fd.RawFdStream {
  self.taken = true
  @raw_fd.RawFdStream(self.fd)
}

///|
fn Fd::close_unless_taken(self : Fd) -> Unit {
  if !self.taken && self.fd >= 0 {
    self.taken = true
    @unix.close_fd(self.fd)
  }
}

///|
const SPAWN_NEW_SESSION : Int32 = 1

///|
const SPAWN_PIPED : Int32 = 2

///|
const SIGTERM : Int32 = 15

///|
const SIGKILL : Int32 = 9

///|
/// Starts a command whose environment is exactly `env`.
/// With `new_session` it leads its own session and process group, which `Child::signal` reaches with `group`.
/// With `piped` its stdin, stdout and stderr are pipes; otherwise it shares this process's.
/// Returns only once exec has succeeded, so a failure here means the command never ran.
fn spawn(
  file : String,
  args : ArrayView[String],
  env : Map[String, String],
  cwd : String,
  piped~ : Bool,
  new_session~ : Bool,
) -> Child raise SpawnFailed {
  let argv : Array[String] = [file]
  argv.append(args.to_owned())
  let entries : Array[String] = []
  for key, value in env {
    if key != "" {
      entries.push("\{key}=\{value}")
    }
  }
  // A NUL would end the string early in C, which could run a different command than the one asked for.
  let strings = [cwd]
  strings.append(argv)
  strings.append(entries)
  guard !strings.iter().any(text => text.contains("\u{0}")) else {
    raise InvalidArgument
  }
  let out = FixedArray::make(4, -1)
  let flags = (if new_session { SPAWN_NEW_SESSION } else { 0 }) |
    (if piped { SPAWN_PIPED } else { 0 })
  let errno = spawn_raw(
    c_string(file),
    pack(argv),
    argv.length(),
    pack(entries),
    entries.length(),
    c_string(cwd),
    flags,
    out,
  )
  if errno != 0 {
    raise SpawnFailed(errno~)
  }
  {
    pid: out[0],
    new_session,
    stdin: Fd::new(out[1]),
    stdout: Fd::new(out[2]),
    stderr: Fd::new(out[3]),
    reaped: false,
    swept: false,
  }
}

///|
fn Child::poll(self : Child) -> Exit? {
  self.collect(0)
}

///|
fn Child::collect(self : Child, timeout_ms : Int32) -> Exit? {
  if self.reaped {
    return None
  }
  let out = FixedArray::make(2, 0)
  let state = wait_raw(self.pid, timeout_ms, out)
  if state == 0 {
    return None
  }
  self.reaped = true
  if state < 0 {
    // The child was reaped elsewhere, so its status is unknown.
    return Some(Code(1))
  }
  Some(if out[0] == 1 { Signaled(out[1]) } else { Code(out[1]) })
}

///|
/// Waits for the child to exit, checking often at first so a short command is not held back.
/// A long wait backs off to `patience_ms` between checks.
async fn Child::wait_exit(
  self : Child,
  patience_ms~ : Int32 = 5,
) -> Exit noraise {
  let started = @async.now()
  let mut exit = self.poll()
  while exit is None {
    @async.sleep(if @async.now() - started < 50L { 1 } else { patience_ms })
    exit = self.poll()
  }
  exit.unwrap()
}

///|
/// False when the signal was not delivered, such as to a child already collected.
fn Child::signal(self : Child, sig : Int32, group~ : Bool) -> Bool {
  if self.reaped && !group {
    return false
  }
  signal_raw(self.pid, if group { 1 } else { 0 }, sig) == 0
}

///|
/// Kills what the child left in its group, which stays reachable by the group id after the child itself is collected.
fn Child::sweep_group(self : Child) -> Unit {
  if self.new_session && !self.swept {
    self.swept = true
    ignore(self.signal(SIGKILL, group=true))
  }
}

///|
/// Ends a run that stops without the child's own exit: kills the group and the child, and collects the child.
/// A child still alive after the bounded wait is left; the caller is reporting a failure by then.
fn Child::stop_and_reap(self : Child) -> Unit {
  self.sweep_group()
  if self.reaped {
    return
  }
  ignore(self.signal(SIGKILL, group=false))
  ignore(self.collect(2000))
}

///|
fn Child::release_pipes(self : Child) -> Unit {
  self.stdin.close_unless_taken()
  self.stdout.close_unless_taken()
  self.stderr.close_unless_taken()
}

///|
fn pack(items : ArrayView[String]) -> Bytes {
  let buffer = @buffer.Buffer()
  for item in items {
    buffer.write_bytes(@utf8.encode(item))
    buffer.write_byte(b'\x00')
  }
  buffer.to_bytes()
}

///|
fn c_string(text : String) -> Bytes {
  pack([text])
}

///|
#borrow(file, argv, env, cwd, out)
extern "C" fn spawn_raw(
  file : Bytes,
  argv : Bytes,
  argc : Int32,
  env : Bytes,
  envc : Int32,
  cwd : Bytes,
  flags : Int32,
  out : FixedArray[Int32],
) -> Int32 = "harnexus_spawn"

///|
#borrow(out)
extern "C" fn wait_raw(
  pid : Int32,
  timeout_ms : Int32,
  out : FixedArray[Int32],
) -> Int32 = "harnexus_wait"

///|
extern "C" fn signal_raw(pid : Int32, to_group : Int32, sig : Int32) -> Int32 = "harnexus_signal"
