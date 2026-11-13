#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <moonbit.h>

// Returns a non-blocking, close-on-exec Unix stream socket, or -errno.
MOONBIT_FFI_EXPORT
int32_t harnexus_socket_open(void) {
  // A write to a peer that has gone must fail with EPIPE rather than kill this process.
  signal(SIGPIPE, SIG_IGN);
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0)
    return -errno;
  // macOS has no SOCK_CLOEXEC, so the flags are set before this function returns and before any child can be spawned.
  int flags = fcntl(fd, F_GETFL);
  if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 || flags < 0 ||
      fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
    int err = errno;
    close(fd);
    return -err;
  }
#ifdef SO_NOSIGPIPE
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
  return fd;
}

// One non-blocking connect attempt: 0 once connected, else the errno.
// The path is NUL-terminated UTF-8 owned by the caller (#borrow).
MOONBIT_FFI_EXPORT
int32_t harnexus_socket_connect(int32_t fd, moonbit_bytes_t path) {
  struct sockaddr_un addr;
  size_t len = strlen((const char *)path);
  if (len >= sizeof(addr.sun_path))
    return ENAMETOOLONG;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  memcpy(addr.sun_path, path, len);
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0)
    return 0;
  // A retry after an earlier attempt completed reports EISCONN, which means connected.
  return errno == EISCONN ? 0 : errno;
}

// Whether a connect errno means "not yet", to be retried until the deadline.
MOONBIT_FFI_EXPORT
int32_t harnexus_socket_connect_pending(int32_t err) {
  return err == EAGAIN || err == EWOULDBLOCK || err == EINPROGRESS || err == EALREADY ||
         err == EINTR;
}
