// SPDX-License-Identifier: GPL-2.0-only
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stopping;
static void stop(int sig) { stopping = sig; }
static int64_t milliseconds(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) abort();
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Keep stdout (daemon protocol) and stderr (arbitrary workload logs) distinct.
 * An oversized line is emitted as plain diagnostic chunks, never as control. */
struct stream {
    int fd;
    char tag;
    int continued;
    size_t used;
    char buffer[8192];
};

static void emit(struct stream *s, int fragment)
{
    char tag = (fragment || s->continued) && s->tag == 'o' ? 'l' : s->tag;
    if (printf("%c\t", tag) < 0 ||
        fwrite(s->buffer, 1, s->used, stdout) != s->used ||
        putchar('\n') == EOF) stopping = SIGPIPE;
    s->used = 0;
    s->continued = fragment;
}

static void drain(struct stream *s)
{
    unsigned char buf[8192];
    ssize_t n;
    if (s->fd < 0) return;
    /* Limit each pass so timeouts and the other pipe always get a turn. */
    for (int pass = 0; pass < 4; pass++) {
        n = read(s->fd, buf, sizeof(buf));
        if (n < 0 && (errno == EAGAIN || errno == EINTR)) return;
        if (n <= 0) {
            if (s->used) emit(s, 0);
            close(s->fd);
            s->fd = -1;
            return;
        }
        for (ssize_t i = 0; i < n; i++) {
            if (buf[i] == '\n') emit(s, 0);
            else {
                if (s->used == sizeof(s->buffer)) emit(s, 1);
                s->buffer[s->used++] = buf[i] ? (char)buf[i] : '?';
            }
        }
    }
}

static int nonblock(int fd)
{
    int flags = fcntl(fd, F_GETFL);
    return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

struct control {
    int queue, pipe;
    char command[256];
    size_t sent, size;
};

/* The controller appends a few fixed ASCII words, each shorter than PIPE_BUF.
 * A partial write to the daemon pipe is retained for the next iteration. */
static int forward_commands(struct control *c)
{
    if (c->queue < 0) return 0;
    if (c->size == c->sent) {
        ssize_t n = read(c->queue, c->command, sizeof(c->command));
        if (n < 0) return errno == EINTR ? 0 : -1;
        if (!n) return 0;
        c->size = (size_t)n;
        c->sent = 0;
    }
    ssize_t n = write(c->pipe, c->command + c->sent, c->size - c->sent);
    if (n > 0) c->sent += (size_t)n;
    else if (n < 0 && errno != EAGAIN && errno != EINTR) return -1;
    return 0;
}

static void close_pair(int p[2]) { close(p[0]); close(p[1]); }
static int supervision(pid_t child, int timeout, struct stream stream[2], struct control *ctl)
{
    int status = 0, result = 0;
    int64_t now = milliseconds(), deadline = now + timeout * (int64_t)1000;
    int64_t term_at = 0, tick = now;
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (;;) {
        now = milliseconds();
        struct pollfd fds[2] = {{stream[0].fd, POLLIN, 0}, {stream[1].fd, POLLIN, 0}};
        if (poll(fds, 2, 60) < 0 && errno != EINTR) stopping = SIGTERM;
        for (int i = 0; i < 2; i++)
            if (fds[i].revents) drain(&stream[i]);
        pid_t ended = waitpid(child, &status, WNOHANG);
        if (ended == child) {
            /* A launch script may leave a background VM with inherited output
             * descriptors. Never wait for that VM when the script has exited. */
            for (int i = 0; i < 2; i++) {
                drain(&stream[i]);
                if (stream[i].fd >= 0 && stream[i].used) emit(&stream[i], 0);
            }
            if (result) return result;
            return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
        }
        if (ended < 0 && errno != EINTR) return 125;
        if (forward_commands(ctl) < 0) {
            close(ctl->queue);
            ctl->queue = -1;
            close(ctl->pipe);
            ctl->pipe = -1;
            stopping = SIGTERM;
        }
        if (now >= tick + 1000) {
            if (puts("t") == EOF) stopping = SIGPIPE;
            tick = now;
        }
        if (!term_at && (stopping || now >= deadline)) {
            result = stopping ? 128 + stopping : 124;
            if (ctl->pipe >= 0) { close(ctl->pipe); ctl->pipe = -1; }
            if (ctl->queue >= 0) { close(ctl->queue); ctl->queue = -1; }
            kill(child, SIGTERM);
            term_at = now;
        } else if (term_at && now - term_at >= 2000) {
            kill(child, SIGKILL);
        }
    }
}

int main(int argc, char **argv)
{
    if (argc < 7 || strcmp(argv[5], "--") || argv[6][0] != '/') return 125;
    char *end;
    long parent = strtol(argv[1], &end, 10);
    if (*end || parent < 2) return 125;
    long timeout = strtol(argv[2], &end, 10);
    if (*end || timeout < 1 || timeout > 2678400) return 125;
    struct sigaction sa = { .sa_handler = stop };
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);
    if (prctl(PR_SET_PDEATHSIG, SIGTERM) || getppid() != parent) return 125;

    struct control ctl = {.queue = -1, .pipe = -1};
    int stdout_pipe[2], stderr_pipe[2], input;
    if (!strcmp(argv[3],"control")) {
        int p[2];
        if (pipe2(p, O_CLOEXEC)) return 125;
        input = p[0];
        ctl.pipe = p[1];
        ctl.queue = open(argv[4], O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (ctl.queue < 0 || nonblock(ctl.pipe)) return 125;
    } else if (!strcmp(argv[3],"input")) {
        input = open(argv[4], O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    } else if (!strcmp(argv[3],"none")) {
        input = open("/dev/null", O_RDONLY | O_CLOEXEC);
    } else return 125;
    if (input < 0 || pipe2(stdout_pipe,O_CLOEXEC) || pipe2(stderr_pipe,O_CLOEXEC)
        || nonblock(stdout_pipe[0]) || nonblock(stderr_pipe[0])) return 125;
    pid_t owner = getpid(), child = fork();
    if (child < 0) return 125;
    if (child == 0) {
        signal(SIGTERM,SIG_DFL); signal(SIGHUP,SIG_DFL); signal(SIGINT,SIG_DFL);
        signal(SIGPIPE,SIG_DFL);
        if (prctl(PR_SET_PDEATHSIG,SIGTERM) || getppid() != owner) _exit(125);
        if (dup2(input,0) < 0 || dup2(stdout_pipe[1],1) < 0 ||
            dup2(stderr_pipe[1],2) < 0) _exit(125);
        close(input);
        close_pair(stdout_pipe); close_pair(stderr_pipe);
        execv(argv[6], argv + 6);
        perror(argv[6]);
        _exit(127);
    }
    close(input); close(stdout_pipe[1]); close(stderr_pipe[1]);
    struct stream streams[2] = {{.fd=stdout_pipe[0], .tag='o'}, {.fd=stderr_pipe[0], .tag='e'}};
    return supervision(child, (int)timeout, streams, &ctl);
}
