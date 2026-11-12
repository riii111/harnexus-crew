///|
#borrow(units)
extern "C" fn string_from_units_raw(
  units : FixedArray[Int32],
  len : Int32,
) -> String = "harnexus_string_from_units"

///|
/// A MoonBit String is UTF-16 and can hold an unpaired surrogate, but only this function builds one; the JSON boundary needs it because JS accepts such a string.
/// Callers of the String get ordinary behaviour for length, equality, hashing and joining, and use `lossy_text` before the text leaves JSON.
fn string_from_units(units : Array[Int32]) -> String {
  string_from_units_raw(FixedArray::from_array(units), units.length())
}

///|
/// How many code units the character at `at` takes: 1, 2 for a surrogate pair, or 0 for an unpaired surrogate.
fn char_width(units : ArrayView[UInt16], at : Int32) -> Int32 {
  let unit = units[at].to_int()
  if unit >= 0xD800 && unit <= 0xDBFF {
    if at + 1 < units.length() &&
      units[at + 1].to_int() >= 0xDC00 &&
      units[at + 1].to_int() <= 0xDFFF {
      2
    } else {
      0
    }
  } else if unit >= 0xDC00 && unit <= 0xDFFF {
    0
  } else {
    1
  }
}
