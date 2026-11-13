#include <pwd.h>
#include <stdint.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#include <moonbit.h>

// Writes the current user's login directory into the caller's buffer and returns its length.
// Returns 0 when the account has no entry or the directory does not fit.
MOONBIT_FFI_EXPORT
int32_t harnexus_login_home(moonbit_bytes_t out, int32_t cap) {
  struct passwd entry;
  struct passwd *found = NULL;
  char scratch[4096];
  if (getpwuid_r(getuid(), &entry, scratch, sizeof scratch, &found) != 0 || found == NULL ||
      entry.pw_dir == NULL)
    return 0;
  size_t len = strlen(entry.pw_dir);
  if (len > (size_t)cap)
    return 0;
  memcpy(out, entry.pw_dir, len);
  return (int32_t)len;
}
