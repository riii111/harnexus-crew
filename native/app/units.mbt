///|
/// The first `count` UTF-16 units; a surrogate pair cut in two leaves U+FFFD in place of its first half.
fn utf16_prefix(text : String, count : Int32) -> String {
  if text.length() <= count {
    text
  } else if text.code_unit_at(count - 1).to_int() is (0xD800..<=0xDBFF) {
    "\{text[:count - 1]}\u{FFFD}"
  } else {
    text[:count].to_owned()
  }
}
