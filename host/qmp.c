// SPDX-License-Identifier: GPL-2.0-only
/* Read-only QMP status. Pin the PID, verify the peer, and match command IDs. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

/* jq is also used by the host bridge. The QMP message is passed as data and
 * never interpolated into the filter. Return OK, SKIP or one bounded status. */
static int parse_reply(const char *line, int id, char answer[80])
{
    static const char filter[] =
        "$r | if type != \"object\" then error(\"invalid QMP object\") "
        "elif $id == 0 then (if (.QMP|type) == \"object\" then \"OK\" else \"SKIP\" end) "
        "elif .id != $id then \"SKIP\" "
        "elif has(\"error\") or (.return|type) != \"object\" then error(\"QMP command failed\") "
        "elif $id == 1 then \"OK\" "
        "else .return.status | if type == \"string\" and test(\"^[a-z][a-z0-9-]{0,63}$\") "
        "then . else error(\"invalid QMP status\") end end";
    char ident[12];
    int p[2], status;
    snprintf(ident, sizeof(ident), "%d", id);
    if (pipe2(p, O_CLOEXEC) < 0) return -1;
    pid_t child = fork();
    if (child == 0) {
        if (dup2(p[1], STDOUT_FILENO) < 0) _exit(125);
        close(p[0]);
        close(p[1]);
        execl("/usr/bin/jq", "jq", "-ner", "--argjson", "r", line,
              "--argjson", "id", ident, filter, (char *)NULL);
        _exit(127);
    }
    close(p[1]);
    if (child < 0) { close(p[0]); return -1; }
    FILE *out = fdopen(p[0], "r");
    int ok = out && fgets(answer, 80, out) && strchr(answer, '\n');
    if (out) fclose(out); else close(p[0]);
    while (waitpid(child, &status, 0) < 0)
        if (errno != EINTR) return -1;
    if (!ok || !WIFEXITED(status) || WEXITSTATUS(status) != 0) return -1;
    answer[strcspn(answer, "\n")] = '\0';
    return 0;
}

static int receive_reply(FILE *stream, int id, char answer[80])
{
    char line[65538];
    while (fgets(line, sizeof(line), stream)) {
        if (!strchr(line, '\n') || strlen(line) > 65536 ||
            parse_reply(line, id, answer)) break;
        if (strcmp(answer, "SKIP")) return 0;
    }
    fputs("Invalid, oversized or missing QMP reply\n", stderr);
    return -1;
}

static int query_status(int fd, char answer[80])
{
    static const char *const command[] = {"", "qmp_capabilities", "query-status"};
    /* Use separate read stream and write syscall to avoid stdio read/write
     * switching on a non-seekable socket. */
    FILE *stream = fdopen(fd, "r");
    if (!stream) return -1;
    int rc = receive_reply(stream, 0, answer);
    for (int id = 1; rc == 0 && id <= 2; id++) {
        if (dprintf(fd, "{\"execute\":\"%s\",\"id\":%d}\r\n", command[id], id) < 0)
            rc = -1;
        else
            rc = receive_reply(stream, id, answer);
    }
    fclose(stream);
    return rc;
}

int main(int argc, char **argv)
{
    if (argc != 4) {
        fputs("Usage: uvp-qmp SOCKET EXPECTED_PID EXPECTED_EXECUTABLE\n", stderr);
        return 2;
    }
    char *end;
    errno = 0;
    long number = strtol(argv[2], &end, 10);
    if (errno || *end || number < 2 || number > INT_MAX) return 2;
    pid_t pid = (pid_t)number;
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    if (strlen(argv[1]) >= sizeof(address.sun_path) || argv[1][0] != '/') {
        fputs("Invalid QMP socket path\n", stderr);
        return 1;
    }
    strcpy(address.sun_path, argv[1]);
    int pidfd = syscall(SYS_pidfd_open, pid, 0);
    if (pidfd < 0) { perror("QEMU pidfd_open"); return 1; }
    char executable[PATH_MAX], path[48];
    snprintf(path, sizeof(path), "/proc/%ld/exe", number);
    ssize_t n = readlink(path, executable, sizeof(executable)-1);
    if (n < 0) { perror("QEMU executable"); return 1; }
    executable[n] = '\0';
    if (strcmp(executable, argv[3])) {
        fputs("Pidfile belongs to a different executable\n", stderr);
        return 1;
    }
    alarm(5);  /* Bound connect, interleaved events, parsing and both replies. */
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0 || connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("QMP socket"); return 1;
    }
    struct ucred peer = {0};
    socklen_t size = sizeof(peer);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &size) < 0 ||
        size != sizeof(peer) || peer.pid != pid) {
        fputs("QMP peer PID differs from configured QEMU pidfile\n", stderr);
        return 1;
    }
    char answer[80];
    struct pollfd target = {.fd = pidfd, .events = POLLIN};
    if (query_status(fd, answer) || poll(&target, 1, 0) != 0) return 1;
    puts(answer);
    return 0;
}
