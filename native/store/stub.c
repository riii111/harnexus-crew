#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <moonbit.h>

// Every function returns a non-negative value on success and the negated errno on failure.
// Paths are NUL-terminated UTF-8 owned by the caller (#borrow) and are not retained.

enum {
  OPEN_READ = 0,
  OPEN_CREATE_EXCLUSIVE = 1,
  OPEN_APPEND = 2,
  OPEN_DIRECTORY = 3,
};

enum {
  KIND_FILE = 1,
  KIND_DIRECTORY = 2,
  KIND_OTHER = 3,
};

static int32_t kind_of(mode_t mode) {
  if (S_ISREG(mode))
    return KIND_FILE;
  if (S_ISDIR(mode))
    return KIND_DIRECTORY;
  return KIND_OTHER;
}

// Descriptors are close-on-exec so that a child started while a lock or temporary file is open never inherits it.
// A read opens non-blocking so that a FIFO cannot hold the caller waiting for a writer.
MOONBIT_FFI_EXPORT
int32_t harnexus_store_open(moonbit_bytes_t path, int32_t how) {
  int flags;
  switch (how) {
  case OPEN_READ:
    flags = O_RDONLY | O_NONBLOCK;
    break;
  case OPEN_CREATE_EXCLUSIVE:
    flags = O_WRONLY | O_CREAT | O_EXCL;
    break;
  case OPEN_APPEND:
    flags = O_WRONLY | O_CREAT | O_APPEND;
    break;
  case OPEN_DIRECTORY:
    flags = O_RDONLY;
    break;
  default:
    return -EINVAL;
  }
  for (;;) {
    int fd = open((const char *)path, flags | O_CLOEXEC, 0600);
    if (fd >= 0)
      return fd;
    if (errno != EINTR)
      return -errno;
  }
}

// A close interrupted by a signal still releases the descriptor, so it is not retried.
MOONBIT_FFI_EXPORT
int32_t harnexus_store_close(int32_t fd) {
  if (close(fd) < 0 && errno != EINTR)
    return -errno;
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t harnexus_store_fsync(int32_t fd) {
  for (;;) {
    if (fsync(fd) == 0)
      return 0;
    if (errno != EINTR)
      return -errno;
  }
}

// Reads at most `len` bytes into the caller's buffer; 0 is the end of the file.
MOONBIT_FFI_EXPORT
int32_t harnexus_store_read(int32_t fd, moonbit_bytes_t buffer, int32_t len) {
  for (;;) {
    ssize_t n = read(fd, buffer, (size_t)len);
    if (n >= 0)
      return (int32_t)n;
    if (errno != EINTR)
      return -errno;
  }
}

// Writes all `len` bytes, retrying partial writes.
MOONBIT_FFI_EXPORT
int32_t harnexus_store_write_all(int32_t fd, moonbit_bytes_t bytes, int32_t len) {
  int32_t done = 0;
  while (done < len) {
    ssize_t n = write(fd, bytes + done, (size_t)(len - done));
    if (n < 0) {
      if (errno == EINTR)
        continue;
      return -errno;
    }
    done += (int32_t)n;
  }
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t harnexus_store_fd_kind(int32_t fd) {
  struct stat info;
  if (fstat(fd, &info) < 0)
    return -errno;
  return kind_of(info.st_mode);
}

// Follows symbolic links, like the stat of the TypeScript boundary.
MOONBIT_FFI_EXPORT
int32_t harnexus_store_path_kind(moonbit_bytes_t path) {
  struct stat info;
  if (stat((const char *)path, &info) < 0)
    return -errno;
  return kind_of(info.st_mode);
}

MOONBIT_FFI_EXPORT
int32_t harnexus_store_rename(moonbit_bytes_t from, moonbit_bytes_t to) {
  return rename((const char *)from, (const char *)to) < 0 ? -errno : 0;
}

// Fails with EEXIST when `to` exists, which is what lets one of several writers create a file.
MOONBIT_FFI_EXPORT
int32_t harnexus_store_link(moonbit_bytes_t from, moonbit_bytes_t to) {
  return link((const char *)from, (const char *)to) < 0 ? -errno : 0;
}

MOONBIT_FFI_EXPORT
int32_t harnexus_store_unlink(moonbit_bytes_t path) {
  return unlink((const char *)path) < 0 ? -errno : 0;
}

MOONBIT_FFI_EXPORT
int32_t harnexus_store_mkdir(moonbit_bytes_t path, int32_t mode) {
  return mkdir((const char *)path, (mode_t)mode) < 0 ? -errno : 0;
}

MOONBIT_FFI_EXPORT
int32_t harnexus_store_rmdir(moonbit_bytes_t path) {
  return rmdir((const char *)path) < 0 ? -errno : 0;
}

// Writes the resolved path into the caller's buffer and returns its length, or ERANGE when it does not fit.
MOONBIT_FFI_EXPORT
int32_t harnexus_store_realpath(moonbit_bytes_t path, moonbit_bytes_t out, int32_t cap) {
  char resolved[PATH_MAX];
  if (realpath((const char *)path, resolved) == NULL)
    return -errno;
  size_t len = strlen(resolved);
  if (len > (size_t)cap)
    return -ERANGE;
  memcpy(out, resolved, len);
  return (int32_t)len;
}

// Writes each entry name followed by a NUL into the caller's buffer, leaving out "." and "..".
// Returns the bytes the full listing needs, so a result above `cap` means the buffer was too small and is to be retried larger.
MOONBIT_FFI_EXPORT
int32_t harnexus_store_list(moonbit_bytes_t path, moonbit_bytes_t out, int32_t cap) {
  DIR *directory = opendir((const char *)path);
  if (directory == NULL)
    return -errno;
  size_t needed = 0;
  struct dirent *entry;
  errno = 0;
  while ((entry = readdir(directory)) != NULL) {
    const char *name = entry->d_name;
    if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0)
      continue;
    size_t len = strlen(name) + 1;
    if (needed + len <= (size_t)cap)
      memcpy(out + needed, name, len);
    needed += len;
  }
  int failed = errno;
  closedir(directory);
  if (failed != 0)
    return -failed;
  return (int32_t)needed;
}

MOONBIT_FFI_EXPORT
int32_t harnexus_store_pid(void) {
  return (int32_t)getpid();
}

// A process that exists but belongs to another user answers EPERM and counts as alive.
MOONBIT_FFI_EXPORT
int32_t harnexus_store_process_alive(int32_t pid) {
  if (kill((pid_t)pid, 0) == 0)
    return 1;
  return errno == EPERM ? 1 : 0;
}

// Writes the symbolic name of an errno into the caller's buffer and returns its length, or 0 for an errno without a name here.
MOONBIT_FFI_EXPORT
int32_t harnexus_store_errno_name(int32_t code, moonbit_bytes_t out, int32_t cap) {
  const char *name = NULL;
  switch (code) {
#define NAMED(value)                                                           \
  case value:                                                                  \
    name = #value;                                                             \
    break
    NAMED(EPERM);
    NAMED(ENOENT);
    NAMED(ESRCH);
    NAMED(EINTR);
    NAMED(EIO);
    NAMED(ENXIO);
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
    NAMED(ERANGE);
    NAMED(ENAMETOOLONG);
    NAMED(ENOTEMPTY);
    NAMED(ELOOP);
    NAMED(EDQUOT);
#undef NAMED
  default:
    return 0;
  }
  size_t len = strlen(name);
  if (len > (size_t)cap)
    return 0;
  memcpy(out, name, len);
  return (int32_t)len;
}

// SHA-256 of `len` bytes into the caller's 32-byte buffer.
static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

static uint32_t rotr(uint32_t value, int bits) {
  return (value >> bits) | (value << (32 - bits));
}

static void sha256_block(uint32_t state[8], const uint8_t block[64]) {
  uint32_t w[64];
  for (int i = 0; i < 16; i++)
    w[i] = ((uint32_t)block[i * 4] << 24) | ((uint32_t)block[i * 4 + 1] << 16) |
           ((uint32_t)block[i * 4 + 2] << 8) | (uint32_t)block[i * 4 + 3];
  for (int i = 16; i < 64; i++) {
    uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
    uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
  uint32_t e = state[4], f = state[5], g = state[6], h = state[7];
  for (int i = 0; i < 64; i++) {
    uint32_t s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
    uint32_t choose = (e & f) ^ (~e & g);
    uint32_t t1 = h + s1 + choose + K[i] + w[i];
    uint32_t s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
    uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
    uint32_t t2 = s0 + majority;
    h = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }
  state[0] += a;
  state[1] += b;
  state[2] += c;
  state[3] += d;
  state[4] += e;
  state[5] += f;
  state[6] += g;
  state[7] += h;
}

MOONBIT_FFI_EXPORT
void harnexus_store_sha256(moonbit_bytes_t bytes, int32_t len, moonbit_bytes_t digest) {
  uint32_t state[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                       0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
  int32_t done = 0;
  while (len - done >= 64) {
    sha256_block(state, bytes + done);
    done += 64;
  }
  uint8_t tail[128];
  int32_t rest = len - done;
  memcpy(tail, bytes + done, (size_t)rest);
  tail[rest] = 0x80;
  int32_t padded = rest + 1 <= 56 ? 64 : 128;
  memset(tail + rest + 1, 0, (size_t)(padded - rest - 1));
  uint64_t bits = (uint64_t)len * 8;
  for (int i = 0; i < 8; i++)
    tail[padded - 1 - i] = (uint8_t)(bits >> (8 * i));
  sha256_block(state, tail);
  if (padded == 128)
    sha256_block(state, tail + 64);
  for (int i = 0; i < 8; i++) {
    digest[i * 4] = (uint8_t)(state[i] >> 24);
    digest[i * 4 + 1] = (uint8_t)(state[i] >> 16);
    digest[i * 4 + 2] = (uint8_t)(state[i] >> 8);
    digest[i * 4 + 3] = (uint8_t)state[i];
  }
}
