///|
priv enum OptionKind {
  Flag
  Text
  TextList
}

///|
priv struct OptionSpec {
  name : String
  kind : OptionKind
  short : Char?
}

///|
priv enum OptionValue {
  On
  One(String)
  Many(Array[String])
}

///|
priv struct ParsedOptions {
  values : Map[String, OptionValue]
}

///|
fn ParsedOptions::flag(self : ParsedOptions, name : String) -> Bool {
  self.values.get(name) is Some(On)
}

///|
fn ParsedOptions::text(self : ParsedOptions, name : String) -> String? {
  match self.values.get(name) {
    Some(One(text)) => Some(text)
    _ => None
  }
}

///|
fn ParsedOptions::list(self : ParsedOptions, name : String) -> Array[String] {
  match self.values.get(name) {
    Some(Many(items)) => items
    _ => []
  }
}

///|
/// The message is worded as Node's `parseArgs` in strict mode words it, which the TypeScript build printed.
pub suberror UsageError {
  UsageError(String)
}

///|
pub fn UsageError::message(self : UsageError) -> String {
  let UsageError(message) = self
  message
}

///|
fn parse_options(
  args : ArrayView[String],
  specs : Array[OptionSpec],
) -> ParsedOptions raise UsageError {
  let values : Map[String, OptionValue] = Map([])
  let mut at = 0
  while at < args.length() {
    let arg = args[at]
    at += 1
    if arg == "--" {
      // No command takes a positional argument, so anything after a lone `--` is a stray one.
      if at < args.length() {
        raise unexpected(args[at])
      }
      break
    }
    if arg.has_prefix("--") {
      let (name, inline) = split_long(arg)
      let spec = find_long(specs, name)
      let raw = "--" + name
      at += take_option(values, spec, raw, inline, args, at)
    } else if arg.has_prefix("-") && arg.length() > 1 {
      at += take_short(values, specs, arg, args, at)
    } else {
      raise unexpected(arg)
    }
  }
  { values, }
}

///|
fn unexpected(arg : String) -> UsageError {
  UsageError(
    "Unexpected argument '\{arg}'. This command does not take positional arguments",
  )
}

///|
fn split_long(arg : String) -> (String, String?) {
  let equals = arg.find("=")
  match equals {
    // A name needs a character before the `=`, so `--=x` is an unknown option as a whole.
    Some(index) if index > 2 =>
      (arg[2:index].to_owned(), Some(arg[index + 1:].to_owned()))
    _ => (arg[2:].to_owned(), None)
  }
}

///|
fn find_long(
  specs : Array[OptionSpec],
  name : String,
) -> OptionSpec raise UsageError {
  for spec in specs {
    if spec.name == name {
      return spec
    }
  }
  raise UsageError("Unknown option '--\{name}'")
}

///|
fn find_short(specs : Array[OptionSpec], unit : UInt16) -> OptionSpec? {
  for spec in specs {
    match spec.short {
      Some(short) if short.to_int() == unit.to_int() => return Some(spec)
      _ => ()
    }
  }
  None
}

///|
fn take_short(
  values : Map[String, OptionValue],
  specs : Array[OptionSpec],
  arg : String,
  args : ArrayView[String],
  at : Int32,
) -> Int32 raise UsageError {
  let units = arg.code_units()
  if units.length() == 2 {
    return match find_short(specs, units[1]) {
      Some(spec) =>
        take_option(values, spec, "-" + show_unit(units[1]), None, args, at)
      None => raise UsageError("Unknown option '-\{show_unit(units[1])}'")
    }
  }
  for index in 1..<units.length() {
    match find_short(specs, units[index]) {
      Some({ kind: Flag, name, .. }) => values[name] = On
      _ => raise UsageError("Unknown option '\{show_unit(units[index])}'")
    }
  }
  0
}

///|
/// A code unit the way it reaches the terminal: half of a surrogate pair prints as U+FFFD.
fn show_unit(unit : UInt16) -> String {
  let code = unit.to_int()
  if code >= 0xD800 && code <= 0xDFFF {
    "\u{FFFD}"
  } else {
    code.unsafe_to_char().to_string()
  }
}

///|
fn take_option(
  values : Map[String, OptionValue],
  spec : OptionSpec,
  raw : String,
  inline : String?,
  args : ArrayView[String],
  at : Int32,
) -> Int32 raise UsageError {
  let shown = match spec.short {
    Some(short) => "-\{short}, --\{spec.name}"
    None => "--\{spec.name}"
  }
  if spec.kind is Flag {
    if inline is Some(_) {
      raise UsageError("Option '\{shown}' does not take an argument")
    }
    values[spec.name] = On
    return 0
  }
  let (value, taken) = match inline {
    Some(text) => (text, 0)
    None => {
      if at >= args.length() {
        raise UsageError("Option '\{shown} <value>' argument missing")
      }
      let next = args[at]
      if next.length() > 1 && next.has_prefix("-") {
        raise UsageError(
          "Option '\{raw}' argument is ambiguous.\nDid you forget to specify the option argument for '\{raw}'?\nTo specify an option argument starting with a dash use '\{raw}=-XYZ'.",
        )
      }
      (next, 1)
    }
  }
  match spec.kind {
    TextList =>
      match values.get(spec.name) {
        Some(Many(items)) => items.push(value)
        _ => values[spec.name] = Many([value])
      }
    _ => values[spec.name] = One(value)
  }
  taken
}
