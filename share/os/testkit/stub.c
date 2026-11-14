#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <moonbit.h>

// Closes the descriptor when it cannot be prepared, so the caller never holds a half-set-up socket.
static int prepare_socket(int fd) {
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 ||
      fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
    int err = errno;
    close(fd);
    return -err;
  }
#ifdef SO_NOSIGPIPE
  // A failure here is ignored, as the product's sockets do.
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
  return fd;
}

static int make_socket(void) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  return fd < 0 ? -errno : prepare_socket(fd);
}

static int fill_address(struct sockaddr_un *addr, moonbit_bytes_t path) {
  size_t len = strlen((const char *)path);
  if (len >= sizeof(addr->sun_path))
    return ENAMETOOLONG;
  memset(addr, 0, sizeof(*addr));
  addr->sun_family = AF_UNIX;
  memcpy(addr->sun_path, path, len);
  return 0;
}

// A listening, non-blocking server socket at `path`, or -errno.
MOONBIT_FFI_EXPORT
int32_t harnexus_testkit_listen(moonbit_bytes_t path, int32_t backlog) {
  struct sockaddr_un addr;
  int err = fill_address(&addr, path);
  if (err != 0)
    return -err;
  unlink(addr.sun_path);
  int fd = make_socket();
  if (fd < 0)
    return fd;
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(fd, backlog) < 0) {
    err = errno;
    close(fd);
    return -err;
  }
  return fd;
}

// One accepted connection, non-blocking, or -errno (EAGAIN while none waits).
MOONBIT_FFI_EXPORT
int32_t harnexus_testkit_accept(int32_t listener) {
  int fd = accept(listener, NULL, NULL);
  return fd < 0 ? -errno : prepare_socket(fd);
}

// One non-blocking connect attempt that leaves the connection open: the descriptor, or -errno.
// It queues on a listener that never accepts, which is how the test fills the listen queue.
MOONBIT_FFI_EXPORT
int32_t harnexus_testkit_connect(moonbit_bytes_t path) {
  struct sockaddr_un addr;
  int err = fill_address(&addr, path);
  if (err != 0)
    return -err;
  int fd = make_socket();
  if (fd < 0)
    return fd;
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    err = errno;
    close(fd);
    return -err;
  }
  return fd;
}

MOONBIT_FFI_EXPORT
int32_t harnexus_testkit_close(int32_t fd) { return close(fd) < 0 ? errno : 0; }

MOONBIT_FFI_EXPORT
void harnexus_testkit_unlink(moonbit_bytes_t path) { unlink((const char *)path); }

// How many descriptors this process has open, to show that a run left none behind.
MOONBIT_FFI_EXPORT
int32_t harnexus_testkit_open_fds(void) {
  int count = 0;
  for (int fd = 0; fd < 1024; fd++) {
    if (fcntl(fd, F_GETFD) != -1)
      count++;
  }
  return count;
}

MOONBIT_FFI_EXPORT
int32_t harnexus_testkit_getpid(void) { return (int32_t)getpid(); }

// Whether the process can still be signalled; a zombie counts as alive.
MOONBIT_FFI_EXPORT
int32_t harnexus_testkit_alive(int32_t pid) { return kill((pid_t)pid, 0) == 0 || errno == EPERM; }

// The errno a non-blocking connect reports when the listen queue is full; its number differs between macOS and Linux.
MOONBIT_FFI_EXPORT
int32_t harnexus_testkit_eagain(void) { return EAGAIN; }

// Returns 0, or the errno with descriptors 0 to 2 left open.
MOONBIT_FFI_EXPORT
int32_t harnexus_testkit_close_stdio(int32_t *saved) {
  for (int i = 0; i < 3; i++) {
    saved[i] = fcntl(i, F_DUPFD_CLOEXEC, 10);
    if (saved[i] < 0) {
      int err = errno;
      for (int j = 0; j < i; j++)
        close(saved[j]);
      return err;
    }
  }
  for (int i = 0; i < 3; i++)
    close(i);
  return 0;
}

MOONBIT_FFI_EXPORT
void harnexus_testkit_restore_stdio(int32_t *saved) {
  for (int i = 0; i < 3; i++) {
    dup2(saved[i], i);
    close(saved[i]);
  }
}

// Whether the descriptor number is open in this process.
MOONBIT_FFI_EXPORT
int32_t harnexus_testkit_fd_open(int32_t fd) { return fcntl(fd, F_GETFD) != -1; }

MOONBIT_FFI_EXPORT
int32_t harnexus_testkit_is_macos(void) {
#if defined(__APPLE__)
  return 1;
#else
  return 0;
#endif
}
