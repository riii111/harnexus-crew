#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <moonbit.h>

#define SPAWN_NEW_SESSION 1
#define SPAWN_PIPED 2

// A spawn holds this lock from creating its pipes until the parent has closed the child's ends, so two spawns never hold each other's descriptors.
// It orders only the spawns made through this file.
static pthread_mutex_t spawn_lock = PTHREAD_MUTEX_INITIALIZER;

static int cloexec_pipe(int fds[2]) {
#ifdef __linux__
  return pipe2(fds, O_CLOEXEC);
#else
  if (pipe(fds) < 0)
    return -1;
  fcntl(fds[0], F_SETFD, FD_CLOEXEC);
  fcntl(fds[1], F_SETFD, FD_CLOEXEC);
  return 0;
#endif
}

// A descriptor below 3 would be overwritten by the dup2 onto stdin, stdout or stderr, so it moves up first.
static int lift_above_stdio(int fd) {
  if (fd < 0 || fd >= 3)
    return fd;
  int moved = fcntl(fd, F_DUPFD_CLOEXEC, 3);
  int err = errno;
  close(fd);
  errno = err;
  return moved;
}

static void close_if_open(int fd) {
  if (fd >= 0)
    close(fd);
}

static int make_nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL);
  return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

// Splits `count` NUL-terminated strings packed in a blob into a NULL-terminated pointer array.
static char **split_blob(moonbit_bytes_t blob, int32_t count) {
  char **list = calloc((size_t)count + 1, sizeof(char *));
  if (list == NULL)
    return NULL;
  char *cursor = (char *)blob;
  for (int32_t i = 0; i < count; i++) {
    list[i] = cursor;
    cursor += strlen(cursor) + 1;
  }
  return list;
}

static const char *env_value(char **envp, const char *name) {
  size_t len = strlen(name);
  for (char **entry = envp; *entry != NULL; entry++) {
    if (strncmp(*entry, name, len) == 0 && (*entry)[len] == '=')
      return *entry + len + 1;
  }
  return NULL;
}

// Looks a bare command name up in the PATH of the environment the command will run in, which is where the TypeScript CLI's runtime looks.
// Without a PATH the usual system directories are searched.
// Returns 0 with the path in `out`, or the errno execvp would give.
static int find_in_path(const char *file, char **envp, char *out, size_t size) {
  const char *path = env_value(envp, "PATH");
  if (path == NULL)
    path = "/usr/bin:/bin";
  int denied = 0;
  const char *dir = path;
  for (;;) {
    const char *end = strchr(dir, ':');
    size_t len = end == NULL ? strlen(dir) : (size_t)(end - dir);
    int written = len == 0 ? snprintf(out, size, "./%s", file)
                           : snprintf(out, size, "%.*s/%s", (int)len, dir, file);
    if (written < 0 || (size_t)written >= size)
      return ENAMETOOLONG;
    struct stat info;
    if (stat(out, &info) == 0 && S_ISREG(info.st_mode)) {
      if (access(out, X_OK) == 0)
        return 0;
      denied = 1;
    }
    if (end == NULL)
      break;
    dir = end + 1;
  }
  return denied ? EACCES : ENOENT;
}

// Runs in the forked child, so it calls only async-signal-safe functions and never allocates.
// Reports the errno of the step that failed on `status_fd`; the descriptor closes on a successful exec.
static void exec_child(const char *path, char **argv, char **envp, const char *cwd,
                       int flags, int in_r, int out_w, int err_w, int status_fd) {
  int err = 0;
  if ((flags & SPAWN_NEW_SESSION) && setsid() < 0) {
    err = errno;
    goto fail;
  }
  if (cwd[0] != '\0' && chdir(cwd) < 0) {
    err = errno;
    goto fail;
  }
  if (flags & SPAWN_PIPED) {
    if (dup2(in_r, 0) < 0 || dup2(out_w, 1) < 0 || dup2(err_w, 2) < 0) {
      err = errno;
      goto fail;
    }
  }
  // The runtime blocks some signals on its threads and ignores SIGPIPE, and both outlive exec.
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = SIG_DFL;
  sigemptyset(&action.sa_mask);
  for (int sig = 1; sig < NSIG; sig++) {
    if (sig != SIGKILL && sig != SIGSTOP)
      sigaction(sig, &action, NULL);
  }
  sigset_t none;
  sigemptyset(&none);
  sigprocmask(SIG_SETMASK, &none, NULL);
  execve(path, argv, envp);
  err = errno;
fail:
  (void)!write(status_fd, &err, sizeof(err));
  _exit(127);
}

// Starts a command and returns 0, or the errno that kept it from running.
// The command never ran when this fails; exec is complete when it succeeds.
// `out` receives the pid and, with SPAWN_PIPED, the parent's ends of stdin, stdout and stderr: non-blocking and close-on-exec.
// With SPAWN_NEW_SESSION the command leads a new session and process group whose id is its pid.
// Without SPAWN_PIPED the command shares this process's stdin, stdout and stderr.
// The strings are NUL-separated UTF-8 blobs owned by the caller (#borrow).
MOONBIT_FFI_EXPORT
int32_t harnexus_spawn(moonbit_bytes_t file, moonbit_bytes_t argv_blob, int32_t argc,
                       moonbit_bytes_t env_blob, int32_t envc, moonbit_bytes_t cwd,
                       int32_t flags, int32_t *out) {
  // A write to a pipe whose reader is gone must fail with EPIPE rather than kill this process.
  signal(SIGPIPE, SIG_IGN);
  char **argv = split_blob(argv_blob, argc);
  char **envp = split_blob(env_blob, envc);
  if (argv == NULL || envp == NULL) {
    free(argv);
    free(envp);
    return ENOMEM;
  }
  char found[PATH_MAX];
  const char *path = (const char *)file;
  int err = 0;
  if (strchr(path, '/') == NULL) {
    err = find_in_path(path, envp, found, sizeof(found));
    path = found;
  }
  if (err != 0) {
    free(argv);
    free(envp);
    return err;
  }

  int in[2] = {-1, -1}, outp[2] = {-1, -1}, errp[2] = {-1, -1}, status[2] = {-1, -1};
  pid_t pid = -1;
  pthread_mutex_lock(&spawn_lock);
  if (cloexec_pipe(status) < 0)
    goto fail;
  if ((flags & SPAWN_PIPED) &&
      (cloexec_pipe(in) < 0 || cloexec_pipe(outp) < 0 || cloexec_pipe(errp) < 0))
    goto fail;
  in[0] = lift_above_stdio(in[0]);
  outp[1] = lift_above_stdio(outp[1]);
  errp[1] = lift_above_stdio(errp[1]);
  if ((flags & SPAWN_PIPED) && (in[0] < 0 || outp[1] < 0 || errp[1] < 0))
    goto fail;

  pid = fork();
  if (pid < 0)
    goto fail;
  if (pid == 0)
    exec_child(path, argv, envp, (const char *)cwd, flags, in[0], outp[1], errp[1], status[1]);

  close_if_open(in[0]);
  close_if_open(outp[1]);
  close_if_open(errp[1]);
  close(status[1]);
  status[1] = -1;
  pthread_mutex_unlock(&spawn_lock);

  // EOF on the status pipe means exec succeeded and closed it; otherwise the child wrote the errno that stopped it.
  int reported = 0;
  ssize_t got;
  do {
    got = read(status[0], &reported, sizeof(reported));
  } while (got < 0 && errno == EINTR);
  close(status[0]);
  free(argv);
  free(envp);
  if (got == (ssize_t)sizeof(reported)) {
    int wait_status;
    while (waitpid(pid, &wait_status, 0) < 0 && errno == EINTR) {
    }
    close_if_open(in[1]);
    close_if_open(outp[0]);
    close_if_open(errp[0]);
    return reported;
  }

  out[0] = (int32_t)pid;
  out[1] = in[1];
  out[2] = outp[0];
  out[3] = errp[0];
  if (flags & SPAWN_PIPED) {
    if (make_nonblocking(in[1]) < 0 || make_nonblocking(outp[0]) < 0 ||
        make_nonblocking(errp[0]) < 0) {
      // The command is running, so it is stopped here rather than reported as never started.
      int failure = errno;
      kill((flags & SPAWN_NEW_SESSION) ? -pid : pid, SIGKILL);
      int wait_status;
      while (waitpid(pid, &wait_status, 0) < 0 && errno == EINTR) {
      }
      close_if_open(in[1]);
      close_if_open(outp[0]);
      close_if_open(errp[0]);
      return failure;
    }
  }
  return 0;

fail:
  err = errno;
  close_if_open(in[0]);
  close_if_open(in[1]);
  close_if_open(outp[0]);
  close_if_open(outp[1]);
  close_if_open(errp[0]);
  close_if_open(errp[1]);
  close_if_open(status[0]);
  close_if_open(status[1]);
  pthread_mutex_unlock(&spawn_lock);
  free(argv);
  free(envp);
  return err;
}

// Reaps the process if it has exited.
// Returns 1 with `out` = {0, exit code} or {1, signal}, 0 while it still runs, or -errno.
// A positive `timeout_ms` polls for that long first, for a process that was just sent SIGKILL.
MOONBIT_FFI_EXPORT
int32_t harnexus_wait(int32_t pid, int32_t timeout_ms, int32_t *out) {
  int status;
  pid_t reaped;
  int32_t waited = 0;
  for (;;) {
    do {
      reaped = waitpid((pid_t)pid, &status, WNOHANG);
    } while (reaped < 0 && errno == EINTR);
    if (reaped != 0 || waited >= timeout_ms)
      break;
    usleep(1000);
    waited++;
  }
  if (reaped == 0)
    return 0;
  if (reaped < 0)
    return -errno;
  if (WIFSIGNALED(status)) {
    out[0] = 1;
    out[1] = WTERMSIG(status);
  } else {
    out[0] = 0;
    out[1] = WEXITSTATUS(status);
  }
  return 1;
}

// Sends a signal to the process, or to its whole process group; returns 0 or the errno.
MOONBIT_FFI_EXPORT
int32_t harnexus_signal(int32_t pid, int32_t to_group, int32_t sig) {
  return kill(to_group ? -(pid_t)pid : (pid_t)pid, sig) < 0 ? errno : 0;
}
