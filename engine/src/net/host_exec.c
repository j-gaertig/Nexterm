#include "host_exec.h"
#include "control_plane.h"
#include "log.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define HOST_EXEC_BUF_SIZE (64 * 1024)
#define HOST_EXEC_DEFAULT_TIMEOUT_MS 30000
#define HOST_EXEC_MAX_TIMEOUT_MS 120000
#define HOST_EXEC_MAX_WORKERS 8
#define HOST_EXEC_STARTUP_TIMEOUT_MS 5000
#define HOST_EXEC_REQUEST_ID_MAX 128
#define HOST_EXEC_EXIT_DRAIN_MS 2000

typedef struct {
    struct nexterm_control_plane* cp;
    char request_id[HOST_EXEC_REQUEST_ID_MAX];
    char* command;
    uint32_t timeout_ms;
} host_exec_args_t;

static pthread_mutex_t g_workers_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_workers_cond = PTHREAD_COND_INITIALIZER;
static int g_workers_active = 0;

static void host_exec_worker_release(void) {
    pthread_mutex_lock(&g_workers_mutex);
    g_workers_active--;
    pthread_cond_signal(&g_workers_cond);
    pthread_mutex_unlock(&g_workers_mutex);
}

void nexterm_host_exec_wait_idle(void) {
    pthread_mutex_lock(&g_workers_mutex);
    while (g_workers_active > 0) {
        pthread_cond_wait(&g_workers_cond, &g_workers_mutex);
    }
    pthread_mutex_unlock(&g_workers_mutex);
}

static uint64_t host_exec_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static void host_exec_args_free(host_exec_args_t* args) {
    if (!args) return;
    free(args->command);
    free(args);
}

static int host_exec_set_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) return -1;
    return 0;
}

static int host_exec_read_fd(int fd, char* buf, size_t cap, size_t* len, bool* truncated) {
    if (*len < cap) {
        ssize_t n = read(fd, buf + *len, cap - *len);
        if (n > 0) {
            *len += (size_t)n;
            return 1;
        }
        if (n == 0) return 0;
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return -1;
        *truncated = true;
        return 0;
    }
    {
        char tmp[1024];
        ssize_t n = read(fd, tmp, sizeof(tmp));
        if (n > 0) {
            *truncated = true;
            return 1;
        }
        if (n == 0) return 0;
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return -1;
        *truncated = true;
        return 0;
    }
}

static void host_exec_drain_stream(int fd, short revents, char* buf, size_t cap,
                                   size_t* len, bool* truncated, bool* eof) {
    if (*eof) return;
    if (!(revents & (POLLIN | POLLHUP | POLLERR))) return;
    for (;;) {
        int r = host_exec_read_fd(fd, buf, cap, len, truncated);
        if (r > 0) continue;
        if (r == 0) *eof = true;
        break;
    }
}

static void host_exec_close_from(int keep_fd) {
    long max_fd = sysconf(_SC_OPEN_MAX);
    if (max_fd < 0 || max_fd > 65536) max_fd = 65536;
    for (int fd = 3; fd < max_fd; fd++) {
        if (fd != keep_fd) close(fd);
    }
}

static void host_exec_kill(pid_t pid, bool pgid_ok) {
    if (pgid_ok) {
        if (kill(-pid, SIGKILL) == 0) return;
        if (errno == ESRCH) return;
        LOG_WARN("HostExec: group kill failed: %s", strerror(errno));
    }
    if (kill(pid, SIGKILL) != 0 && errno != ESRCH) {
        LOG_WARN("HostExec: kill failed: %s", strerror(errno));
    }
}

static void host_exec_child_fail(int exec_fd) {
    int e = errno;
    ssize_t w = write(exec_fd, &e, sizeof(e));
    (void)w;
    _exit(127);
}

static void* host_exec_thread(void* arg) {
    host_exec_args_t* args = (host_exec_args_t*)arg;
    int out_pipe[2] = {-1, -1};
    int err_pipe[2] = {-1, -1};
    int exec_pipe[2] = {-1, -1};
    pid_t pid = -1;
    bool pgid_ok = false;

    char* stdout_buf = malloc(HOST_EXEC_BUF_SIZE + 1);
    char* stderr_buf = malloc(HOST_EXEC_BUF_SIZE + 1);
    if (!stdout_buf || !stderr_buf) {
        free(stdout_buf);
        free(stderr_buf);
        nexterm_cp_send_host_exec_result(args->cp, args->request_id, false,
                                         NULL, NULL, -1, "Out of memory", false);
        goto release;
    }
    size_t stdout_len = 0;
    size_t stderr_len = 0;
    bool stdout_trunc = false;
    bool stderr_trunc = false;

    if (pipe(out_pipe) != 0 || pipe(err_pipe) != 0 || pipe(exec_pipe) != 0) {
        nexterm_cp_send_host_exec_result(args->cp, args->request_id, false,
                                         NULL, NULL, -1, "Failed to create pipes", false);
        goto done;
    }
    if (host_exec_set_nonblock(out_pipe[0]) != 0 ||
        host_exec_set_nonblock(err_pipe[0]) != 0 ||
        fcntl(exec_pipe[0], F_SETFD, FD_CLOEXEC) != 0 ||
        fcntl(exec_pipe[1], F_SETFD, FD_CLOEXEC) != 0) {
        nexterm_cp_send_host_exec_result(args->cp, args->request_id, false,
                                         NULL, NULL, -1, "Failed to configure pipes", false);
        goto done;
    }

    pid = fork();
    if (pid < 0) {
        nexterm_cp_send_host_exec_result(args->cp, args->request_id, false,
                                         NULL, NULL, -1, "Failed to fork", false);
        goto done;
    }

    if (pid == 0) {
        close(exec_pipe[0]);
        if (setpgid(0, 0) != 0) host_exec_child_fail(exec_pipe[1]);
        {
            int nullfd = open("/dev/null", O_RDONLY);
            if (nullfd < 0) host_exec_child_fail(exec_pipe[1]);
            if (dup2(nullfd, STDIN_FILENO) < 0) host_exec_child_fail(exec_pipe[1]);
            if (nullfd > STDIN_FILENO) close(nullfd);
        }
        if (dup2(out_pipe[1], STDOUT_FILENO) < 0) host_exec_child_fail(exec_pipe[1]);
        if (dup2(err_pipe[1], STDERR_FILENO) < 0) host_exec_child_fail(exec_pipe[1]);
        signal(SIGPIPE, SIG_DFL);
        host_exec_close_from(exec_pipe[1]);
        execl("/bin/sh", "sh", "-c", args->command, (char*)NULL);
        host_exec_child_fail(exec_pipe[1]);
    }

    pgid_ok = (setpgid(pid, pid) == 0);

    close(out_pipe[1]);
    out_pipe[1] = -1;
    close(err_pipe[1]);
    err_pipe[1] = -1;
    close(exec_pipe[1]);
    exec_pipe[1] = -1;

    {
        struct pollfd pfd;
        pfd.fd = exec_pipe[0];
        pfd.events = POLLIN;
        bool started = false;
        uint64_t start_deadline = host_exec_now_ms() + HOST_EXEC_STARTUP_TIMEOUT_MS;
        while (!started) {
            uint64_t now = host_exec_now_ms();
            if (now >= start_deadline) break;
            int pr = poll(&pfd, 1, (int)(start_deadline - now));
            if (pr < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (pr == 0) break;
            {
                int exec_errno = 0;
                ssize_t n = read(exec_pipe[0], &exec_errno, sizeof(exec_errno));
                if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) continue;
                if (n != 0) {
                    int status = 0;
                    waitpid(pid, &status, 0);
                    pid = -1;
                    nexterm_cp_send_host_exec_result(args->cp, args->request_id, false,
                                                     NULL, NULL, -1,
                                                     "Failed to start shell", false);
                    goto done;
                }
                started = true;
            }
        }
        close(exec_pipe[0]);
        exec_pipe[0] = -1;
        if (!started) {
            if (pid > 0) {
                host_exec_kill(pid, pgid_ok);
                int status = 0;
                waitpid(pid, &status, 0);
                pid = -1;
            }
            nexterm_cp_send_host_exec_result(args->cp, args->request_id, false,
                                             NULL, NULL, -1,
                                             "Shell startup timed out", false);
            goto done;
        }
        pgid_ok = true;
    }

    {
        uint32_t timeout_ms = args->timeout_ms;
        if (timeout_ms == 0) timeout_ms = HOST_EXEC_DEFAULT_TIMEOUT_MS;
        if (timeout_ms > HOST_EXEC_MAX_TIMEOUT_MS) timeout_ms = HOST_EXEC_MAX_TIMEOUT_MS;
        uint64_t deadline = host_exec_now_ms() + timeout_ms;
        bool timed_out = false;
        bool child_done = false;
        bool wait_failed = false;
        int child_status = 0;
        bool out_eof = false;
        bool err_eof = false;
        uint64_t exited_at = 0;

        while (!child_done || !out_eof || !err_eof) {
            if (!timed_out && !child_done && host_exec_now_ms() >= deadline) {
                pid_t w = waitpid(pid, &child_status, WNOHANG);
                if (w == pid) {
                    child_done = true;
                    exited_at = host_exec_now_ms();
                } else {
                    timed_out = true;
                    host_exec_kill(pid, pgid_ok);
                }
            }

            if (child_done && !timed_out && !(out_eof && err_eof)) {
                if (exited_at == 0) exited_at = host_exec_now_ms();
                if (host_exec_now_ms() - exited_at >= HOST_EXEC_EXIT_DRAIN_MS) {
                    host_exec_kill(pid, pgid_ok);
                    break;
                }
            }

            struct pollfd pfds[2];
            pfds[0].fd = out_pipe[0];
            pfds[0].events = POLLIN;
            pfds[1].fd = err_pipe[0];
            pfds[1].events = POLLIN;
            int pr = poll(pfds, 2, 250);
            if (pr < 0 && errno != EINTR) {
                LOG_WARN("HostExec: req=%s poll failed", args->request_id);
            }

            host_exec_drain_stream(out_pipe[0], pr > 0 ? pfds[0].revents : 0, stdout_buf,
                                   HOST_EXEC_BUF_SIZE, &stdout_len, &stdout_trunc,
                                   &out_eof);
            host_exec_drain_stream(err_pipe[0], pr > 0 ? pfds[1].revents : 0, stderr_buf,
                                   HOST_EXEC_BUF_SIZE, &stderr_len, &stderr_trunc,
                                   &err_eof);

            if (!child_done) {
                pid_t w = waitpid(pid, &child_status, WNOHANG);
                if (w == pid) {
                    child_done = true;
                    exited_at = host_exec_now_ms();
                } else if (w < 0 && errno != EINTR) {
                    LOG_WARN("HostExec: req=%s wait failed", args->request_id);
                    wait_failed = true;
                    child_done = true;
                    host_exec_kill(pid, pgid_ok);
                    {
                        int status = 0;
                        waitpid(pid, &status, 0);
                    }
                    break;
                }
            }

            if (child_done && (timed_out || (out_eof && err_eof))) break;
        }

        stdout_buf[stdout_len] = '\0';
        stderr_buf[stderr_len] = '\0';
        bool truncated = stdout_trunc || stderr_trunc;

        if (timed_out) {
            nexterm_cp_send_host_exec_result(args->cp, args->request_id, false,
                                             stdout_buf, stderr_buf, -1,
                                             "Host command timed out", truncated);
        } else if (wait_failed) {
            nexterm_cp_send_host_exec_result(args->cp, args->request_id, false,
                                             stdout_buf, stderr_buf, -1,
                                             "Host command wait failed", truncated);
        } else if (WIFEXITED(child_status)) {
            int exit_code = WEXITSTATUS(child_status);
            nexterm_cp_send_host_exec_result(args->cp, args->request_id,
                                             exit_code == 0,
                                             stdout_buf, stderr_buf,
                                             exit_code, NULL, truncated);
        } else {
            nexterm_cp_send_host_exec_result(args->cp, args->request_id, false,
                                             stdout_buf, stderr_buf, -1,
                                             "Host command terminated by signal", truncated);
        }

        if (truncated) {
            LOG_INFO("HostExec: req=%s output truncated at %d bytes",
                     args->request_id, HOST_EXEC_BUF_SIZE);
        }
        pid = -1;
    }

done:
    if (pid > 0) {
        host_exec_kill(pid, pgid_ok);
        int status = 0;
        waitpid(pid, &status, 0);
    }
    if (out_pipe[0] >= 0) close(out_pipe[0]);
    if (out_pipe[1] >= 0) close(out_pipe[1]);
    if (err_pipe[0] >= 0) close(err_pipe[0]);
    if (err_pipe[1] >= 0) close(err_pipe[1]);
    if (exec_pipe[0] >= 0) close(exec_pipe[0]);
    if (exec_pipe[1] >= 0) close(exec_pipe[1]);
    free(stdout_buf);
    free(stderr_buf);
release:
    host_exec_args_free(args);
    host_exec_worker_release();
    return NULL;
}

int nexterm_host_exec(struct nexterm_control_plane* cp,
                      const char* request_id,
                      const char* command,
                      uint32_t timeout_ms) {
    if (!cp || !request_id || request_id[0] == '\0' || !command || command[0] == '\0') return -1;

    if (strlen(request_id) >= HOST_EXEC_REQUEST_ID_MAX) {
        LOG_WARN("HostExec: request id too long");
        nexterm_cp_send_host_exec_result(cp, request_id, false,
                                         NULL, NULL, -1,
                                         "Request id too long", false);
        return -2;
    }

    pthread_mutex_lock(&g_workers_mutex);
    if (g_workers_active >= HOST_EXEC_MAX_WORKERS) {
        pthread_mutex_unlock(&g_workers_mutex);
        LOG_WARN("HostExec: worker limit reached");
        nexterm_cp_send_host_exec_result(cp, request_id, false,
                                         NULL, NULL, -1,
                                         "Engine is busy", false);
        return -2;
    }
    g_workers_active++;
    pthread_mutex_unlock(&g_workers_mutex);

    host_exec_args_t* args = calloc(1, sizeof(host_exec_args_t));
    if (!args) {
        host_exec_worker_release();
        return -1;
    }

    args->cp = cp;
    snprintf(args->request_id, sizeof(args->request_id), "%s", request_id);
    args->command = strdup(command);
    args->timeout_ms = timeout_ms;
    if (!args->command) {
        free(args);
        host_exec_worker_release();
        return -1;
    }

    LOG_INFO("HostExec: req=%s cmdlen=%zu...", request_id, strlen(command));

    pthread_t thread;
    if (pthread_create(&thread, NULL, host_exec_thread, args) != 0) {
        LOG_ERROR("Failed to create host exec thread for %s", request_id);
        host_exec_args_free(args);
        host_exec_worker_release();
        return -1;
    }
    if (pthread_detach(thread) != 0) {
        LOG_WARN("Failed to detach host exec thread for %s", request_id);
    }
    return 0;
}
