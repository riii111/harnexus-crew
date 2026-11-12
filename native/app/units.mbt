///|
/// The first `count` UTF-16 units, as `slice(0, count)` takes them: a surrogate pair cut in two leaves its first half unpaired.
/// A String is only built with an unpaired surrogate by reading JSON, so the units go through a JSON string of escapes.
fn utf16_prefix(text : String, count : Int32) -> String {
  if text.length() <= count {
    return text
  }
  let units = text.code_units()
  let escaped = StringBuilder()
  escaped.write_char('"')
  for index in 0..<count {
    escaped.write_string("\\u\{hex4(units[index].to_int())}")
  }
  escaped.write_char('"')
  match (@jsonio.parse(escaped.to_string()) catch { _ => Json::null() }) {
    String(prefix) => prefix
    _ => abort("a string of escapes is a JSON string")
  }
}

///|
fn hex4(unit : Int32) -> String {
  let digits = "0123456789abcdef"
  let out = StringBuilder()
  for shift in [12, 8, 4, 0] {
    out.write_char(digits[(unit >> shift) & 15].to_char().unwrap())
  }
  out.to_string()
}
