#include <errno.h>
#include <stdint.h>
#include <unistd.h>

#include <moonbit.h>

// The index is the position in the MoonBit table of names.
// errno numbers differ between macOS and Linux, so the table is keyed by the macro.
MOONBIT_FFI_EXPORT
int32_t harnexus_errno_index(int32_t err) {
  switch (err) {
  case ENOENT:
    return 1;
  case EACCES:
    return 2;
  case EPERM:
    return 3;
  case ECONNREFUSED:
    return 4;
  case ECONNRESET:
    return 5;
  case EPIPE:
    return 6;
  case ETIMEDOUT:
    return 7;
  case EAGAIN:
    return 8;
  case ENOTSOCK:
    return 9;
  case ENAMETOOLONG:
    return 10;
  case EMFILE:
    return 11;
  case ENFILE:
    return 12;
  case ENOMEM:
    return 13;
  case ENOTDIR:
    return 14;
  case ELOOP:
    return 15;
  case EIO:
    return 16;
  case ENOEXEC:
    return 17;
  case E2BIG:
    return 18;
  case ETXTBSY:
    return 19;
  case EISDIR:
    return 20;
  case EINVAL:
    return 21;
  case EADDRNOTAVAIL:
    return 22;
  case EAFNOSUPPORT:
    return 23;
  case EPROTOTYPE:
    return 24;
  case ENOBUFS:
    return 25;
  case EINTR:
    return 26;
  case EBADF:
    return 27;
  case ENOTCONN:
    return 28;
  case EINPROGRESS:
    return 29;
  case EALREADY:
    return 30;
  case EISCONN:
    return 31;
  case ECONNABORTED:
    return 32;
  default:
    return 0;
  }
}

// Returns 0 or the errno of close.
// close is not retried on EINTR: the descriptor is already released then, and a retry could close another thread's new descriptor.
MOONBIT_FFI_EXPORT
int32_t harnexus_close_fd(int32_t fd) { return close(fd) < 0 ? errno : 0; }
