///|
pub suberror UsageError {
  UsageError(String)
}

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
        raise unexpected_argument(args[at])
      }

      break
    }

    if arg.has_prefix("--") {
      let (name, inline) = split_long(arg)
      let spec = find_long(specs, name)
      at += take_option(values, spec, inline, args, at)
    } else if arg == "-h" && specs.iter().any(fn(spec) { spec.name == "help" }) {
      values["help"] = On
    } else if arg.has_prefix("-") && arg.length() > 1 {
      raise UsageError("Unknown option '\{arg}'")
    } else {
      raise unexpected_argument(arg)
    }
  }

  { values, }
}

///|
fn take_option(
  values : Map[String, OptionValue],
  spec : OptionSpec,
  inline : String?,
  args : ArrayView[String],
  at : Int32,
) -> Int32 raise UsageError {
  let shown = "--\{spec.name}"

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
          "Option '\{shown}' argument is ambiguous.\nDid you forget to specify the option argument for '\{shown}'?\nTo specify an option argument starting with a dash use '\{shown}=-XYZ'.",
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
fn unexpected_argument(arg : String) -> UsageError {
  UsageError(
    "Unexpected argument '\{arg}'. This command does not take positional arguments",
  )
}
