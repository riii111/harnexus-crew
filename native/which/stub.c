#include <stdint.h>
#include <sys/stat.h>
#include <unistd.h>

#include <moonbit.h>

// Answers 1 for a regular file, reached through symbolic links, that the current user may execute.
MOONBIT_FFI_EXPORT
int32_t harnexus_is_runnable_file(moonbit_bytes_t path) {
  struct stat entry;
  if (stat((const char *)path, &entry) != 0 || !S_ISREG(entry.st_mode))
    return 0;
  return access((const char *)path, X_OK) == 0 ? 1 : 0;
}
