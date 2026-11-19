// SPDX-License-Identifier: GPL-2.0-only
/* Test-only QMP peer. Accept one connection and interleave an event with each reply. */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    struct sockaddr_un addr = {.sun_family=AF_UNIX};
    if (strlen(argv[1]) >= sizeof(addr.sun_path)) return 1;
    strcpy(addr.sun_path, argv[1]);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0 && (errno == EPERM || errno == EACCES)) return 77;
    if (fd < 0 || bind(fd, (struct sockaddr *)&addr, sizeof(addr)) || listen(fd, 1)) return 1;
    int peer = accept(fd, NULL, NULL);
    if (peer < 0) return 1;
    FILE *f = fdopen(peer, "r");
    if (!f) return 1;
    if (dprintf(peer, "{\"QMP\":{\"version\":{}}}\r\n") < 0) return 1;
    char line[256];
    for (int i=1; i<=2; i++) {
        if (!fgets(line, sizeof(line), f)) return 1;
        if (!strstr(line, i==1 ? "qmp_capabilities" : "query-status")) return 1;
        if (dprintf(peer, "{\"event\":\"RESUME\"}\r\n{\"return\":{},\"id\":9000}\r\n"
                    "{\"id\":%d,\"return\":%s}\r\n", i, i==1 ? "{}" : "{\"status\":\"inmigrate\"}") < 0)
            return 1;
    }
    /* The client verifies the target is still alive after the final reply. */
    fclose(f);
    sleep(1);
    return 0;
}
