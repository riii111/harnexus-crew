#include <stdint.h>

#include <moonbit.h>

// Builds a String from UTF-16 code units, including an unpaired surrogate, which no MoonBit String constructor accepts.
// `units` is owned by the caller (#borrow) and holds one code unit per element.
MOONBIT_FFI_EXPORT
moonbit_string_t harnexus_string_from_units(int32_t *units, int32_t len) {
  moonbit_string_t text = moonbit_make_string_raw(len);
  for (int32_t i = 0; i < len; i++)
    text[i] = (uint16_t)units[i];
  return text;
}
