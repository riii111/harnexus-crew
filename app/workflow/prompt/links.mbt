///|
/// Resolve relative template links to existing files.
fn resolve_links(
  template : String,
  path : String,
  fields : Map[String, String],
) -> String raise @failure.TaskFailed {
  // The layout is the one the templates were written in, so a symlinked template resolves beside its real file.
  let folder = @path.dirname(@store.real_path_or_self(path))
  let nonce = @store.new_uuid().replace_all(old="-", new="")
  let out = StringBuilder()
  let mut last = 0
  for candidate in @markdown.links(template, nonce~) {
    let raw = candidate.raw
    let hash = raw.find("#")
    let raw_path = match hash {
      Some(at) => raw[:at].to_owned()
      None => raw
    }
    if !is_relative(@text.js_trim(without_angle(raw_path))) {
      continue
    }
    // The app attaches a skill only from a bare target, so a relative one with angle brackets, a space or a title would reach the chat unresolved.
    if raw.has_prefix("<") || @text.has_space(raw) {
      @failure.fail(
        "links to \"\{raw}\"; write a relative target without angle brackets, spaces or a title",
      )
    }
    let target = @template.format(
      raw_path,
      fields,
      refuse=@template.refuse_unless_name,
    )
    let file = @path.resolve(cwd=folder, [folder, target])
    if !@store.is_file(file) {
      @failure.fail("links to \{file}, which is not a file")
    }
    let real = @store.real_path_or_self(file)
    // A link target ends at a space or parenthesis, and Markdown reads a # as an anchor and a backslash as an escape.
    if has_unsafe_character(real) {
      @failure.fail(
        "links to \{real}, whose path has a space, parenthesis, # or backslash",
      )
    }
    let fragment = match hash {
      Some(at) =>
        @template.format(
          raw[at:].to_owned(),
          fields,
          refuse=@template.refuse_unless_name,
        )
      None => ""
    }
    out.write_view(template[last:candidate.start])
    out.write_string(@template.escape_braces(real + fragment))
    last = candidate.end
  }
  out.write_view(template[last:])
  out.to_string()
}

///|
fn is_relative(path : String) -> Bool {
  path != "" &&
  !path.has_prefix("/") &&
  // A target opening with a field is the value's to decide, as with {pr_url} or {checkout}.
  !(path.has_prefix("{") && !path.has_prefix("{{")) &&
  !has_scheme(path)
}

///|
fn has_unsafe_character(path : String) -> Bool {
  @text.has_space(path) ||
  path
  .code_units()
  .iter()
  .any(fn(unit) { unit == '(' || unit == ')' || unit == '#' || unit == '\\' })
}

///|
fn without_angle(path : String) -> String {
  match path.strip_prefix("<") {
    Some(rest) => rest.to_owned()
    None => path
  }
}

///|
fn has_scheme(path : String) -> Bool {
  let units = path.code_units()
  if units.length() == 0 || !is_ascii_letter(units[0]) {
    return false
  }
  for index in 1..<units.length() {
    let unit = units[index]
    if unit == ':' {
      return true
    }
    if !(@text.is_ascii_alphanumeric(unit.to_int()) ||
      unit == '+' ||
      unit == '.' ||
      unit == '-') {
      return false
    }
  }
  false
}

///|
fn is_ascii_letter(unit : UInt16) -> Bool {
  (unit >= 'A' && unit <= 'Z') || (unit >= 'a' && unit <= 'z')
}
