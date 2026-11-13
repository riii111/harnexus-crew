#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#include <moonbit.h>

// Writes the symbolic name of an errno into the caller's buffer and returns its length, or 0 for an errno without a name here.
// errno numbers differ between macOS and Linux, so the names come from the macros.
MOONBIT_FFI_EXPORT
int32_t harnexus_errno_name(int32_t code, moonbit_bytes_t out, int32_t cap) {
  const char *name = NULL;
  switch (code) {
#define NAMED(value)                                                                               \
  case value:                                                                                      \
    name = #value;                                                                                 \
    break
    NAMED(EPERM);
    NAMED(ENOENT);
    NAMED(ESRCH);
    NAMED(EINTR);
    NAMED(EIO);
    NAMED(ENXIO);
    NAMED(E2BIG);
    NAMED(ENOEXEC);
    NAMED(EBADF);
    NAMED(EAGAIN);
    NAMED(ENOMEM);
    NAMED(EACCES);
    NAMED(EBUSY);
    NAMED(EEXIST);
    NAMED(EXDEV);
    NAMED(ENODEV);
    NAMED(ENOTDIR);
    NAMED(EISDIR);
    NAMED(EINVAL);
    NAMED(ENFILE);
    NAMED(EMFILE);
    NAMED(ETXTBSY);
    NAMED(EFBIG);
    NAMED(ENOSPC);
    NAMED(EROFS);
    NAMED(EMLINK);
    NAMED(EPIPE);
    NAMED(ERANGE);
    NAMED(ENAMETOOLONG);
    NAMED(ENOTEMPTY);
    NAMED(ELOOP);
    NAMED(EDQUOT);
    NAMED(ENOTSOCK);
    NAMED(EPROTOTYPE);
    NAMED(EAFNOSUPPORT);
    NAMED(EADDRNOTAVAIL);
    NAMED(ENOBUFS);
    NAMED(ENOTCONN);
    NAMED(ECONNABORTED);
    NAMED(ECONNRESET);
    NAMED(ECONNREFUSED);
    NAMED(ETIMEDOUT);
    NAMED(EINPROGRESS);
    NAMED(EALREADY);
    NAMED(EISCONN);
#undef NAMED
  default:
    return 0;
  }
  size_t len = strlen(name);
  if (len > (size_t)cap)
    return 0;
  // NOLINTNEXTLINE(bugprone-not-null-terminated-result): MoonBit reads the returned length, not a NUL.
  memcpy(out, name, len);
  return (int32_t)len;
}

// Returns 0 or the errno of close.
// close is not retried on EINTR: the descriptor is already released then, and a retry could close another thread's new descriptor.
MOONBIT_FFI_EXPORT
int32_t harnexus_close_fd(int32_t fd) { return close(fd) < 0 ? errno : 0; }
