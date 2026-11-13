///|
/// Where one kind of state for `key` lives under the state root.
/// The directory is named by the first 16 hex digits of the SHA-256 of `key`, so a change to how a kind lays out its key would lose the directories already recorded under it.
pub fn state_directory(root : String, kind : String, key : String) -> String {
  "\{root}/\{kind}/\{sha256_hex(key)[:16]}"
}

///|
/// A random version 4 UUID in lower-case hex, as `crypto.randomUUID` writes it.
pub fn new_uuid() -> String {
  let bytes = match @env.rand(16) {
    Some(bytes) => bytes
    None => abort("no source of random bytes")
  }
  let hex = StringBuilder()
  for index in 0..<16 {
    if index == 4 || index == 6 || index == 8 || index == 10 {
      hex.write_char('-')
    }
    let byte = match index {
      6 => (bytes[index].to_int() & 0x0F) | 0x40
      8 => (bytes[index].to_int() & 0x3F) | 0x80
      _ => bytes[index].to_int()
    }
    hex.write_string(hex_byte(byte))
  }
  hex.to_string()
}

///|
/// The current time as `Date#toISOString` writes it: UTC with milliseconds.
pub fn now_iso() -> String {
  iso_time(@env.now().reinterpret_as_int64())
}

///|
/// The process id of this program.
pub fn current_pid() -> Int32 {
  pid_raw()
}

///|
/// Whether a process with that id exists.
/// A process of another user counts as alive.
/// A value that is not a 32-bit integer is dead, as `process.kill` of Node refuses it.
/// 0 and -1 signal process groups, so they count as alive.
pub fn process_alive(pid : Double) -> Bool {
  if pid != pid.floor() || pid < -2147483648.0 || pid > 2147483647.0 {
    return false
  }
  process_alive_raw(pid.to_int()) == 1
}

///|
/// The SHA-256 of the UTF-8 text in lower-case hex, as `createHash("sha256")` writes it.
pub fn sha256_hex(text : String) -> String {
  let bytes = @utf8.encode(text)
  let digest : FixedArray[Byte] = FixedArray::make(32, b'\x00')
  sha256_raw(bytes, bytes.length(), digest)
  let hex = StringBuilder()
  for byte in digest {
    hex.write_string(hex_byte(byte.to_int()))
  }
  hex.to_string()
}

///|
fn hex_byte(value : Int32) -> String {
  let digits = "0123456789abcdef"
  "\{digits[value / 16].to_char().unwrap()}\{digits[value % 16].to_char().unwrap()}"
}

///|
/// Formats milliseconds since the epoch as an ISO 8601 UTC time.
fn iso_time(millis : Int64) -> String {
  let days = millis / 86400000L
  let of_day = (millis % 86400000L).to_int()
  // Civil date from a day count, after Howard Hinnant's algorithm: years run from March so the leap day is the last of the year.
  let shifted = days + 719468L
  let era = shifted / 146097L
  let day_of_era = (shifted % 146097L).to_int()
  let year_of_era = (
      day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096
    ) /
    365
  let day_of_year = day_of_era -
    (365 * year_of_era + year_of_era / 4 - year_of_era / 100)
  let month_from_march = (5 * day_of_year + 2) / 153
  let day = day_of_year - (153 * month_from_march + 2) / 5 + 1
  let month = if month_from_march < 10 {
    month_from_march + 3
  } else {
    month_from_march - 9
  }
  let year = era.to_int() * 400 + year_of_era + (if month <= 2 { 1 } else { 0 })
  let hour = of_day / 3600000
  let minute = of_day / 60000 % 60
  let second = of_day / 1000 % 60
  let milli = of_day % 1000
  "\{pad(year, 4)}-\{pad(month, 2)}-\{pad(day, 2)}T\{pad(hour, 2)}:\{pad(minute, 2)}:\{pad(second, 2)}.\{pad(milli, 3)}Z"
}

///|
fn pad(value : Int32, width : Int32) -> String {
  let digits = value.to_string()
  "0".repeat(width - digits.length()) + digits
}
