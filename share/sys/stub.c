#include <errno.h>
#include <stdint.h>
#include <unistd.h>

#include <moonbit.h>

MOONBIT_FFI_EXPORT
int32_t harnexus_platform(void) {
#if defined(__APPLE__)
  return 1;
#elif defined(__linux__)
  return 2;
#else
  return 0;
#endif
}

// Returns 0 once all `len` bytes are written, else the errno of the failing write.
// The buffer is owned by the caller (#borrow) and is not retained.
MOONBIT_FFI_EXPORT
int32_t harnexus_write_all(int32_t fd, moonbit_bytes_t bytes, int32_t len) {
  int32_t done = 0;
  while (done < len) {
    ssize_t n = write(fd, bytes + done, (size_t)(len - done));
    if (n < 0) {
      if (errno == EINTR)
        continue;
      return errno;
    }
    done += (int32_t)n;
  }
  return 0;
}
