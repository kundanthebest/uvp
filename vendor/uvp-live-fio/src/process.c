// SPDX-License-Identifier: GPL-2.0-only
#define _GNU_SOURCE
#include "process.h"
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

uint64_t now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
void sleep_ms(unsigned int ms)
{
    struct timespec t = {ms / 1000, (ms % 1000) * 1000000L};
    while (nanosleep(&t, &t) && errno == EINTR) { }
}
int open_pidfd(pid_t pid) { return syscall(SYS_pidfd_open, pid, 0); }
int signal_pidfd(int fd, int sig)
{ return syscall(SYS_pidfd_send_signal, fd, sig, NULL, 0); }
int pidfd_exited(int fd)
{
    struct pollfd p = {.fd = fd, .events = POLLIN};
    int r = poll(&p, 1, 0);
    return r > 0 && p.revents;
}
int check_process(pid_t pid)
{
    char path[128], line[256];
    FILE *f;
    long tgid = -1, tracer = -1;
    snprintf(path, sizeof(path), "/proc/%d/status", pid);
    f = fopen(path, "r");
    if (!f) return -1;
    while (fgets(line, sizeof(line), f)) {
        if (!strncmp(line, "Tgid:", 5)) tgid = strtol(line + 5, NULL, 10);
        if (!strncmp(line, "TracerPid:", 10)) tracer = strtol(line + 10, NULL, 10);
    }
    fclose(f);
    if (tgid != pid || tracer != 0) { errno = EINVAL; return -1; }
    return 0;
}
struct snapshot { uint64_t sum, sum2; unsigned int count; };
static int stopped_snapshot(pid_t pid, struct snapshot *s)
{
    char path[160], line[256], state;
    DIR *d;
    struct dirent *e;
    int all = 1;
    memset(s, 0, sizeof(*s));
    snprintf(path, sizeof(path), "/proc/%d/task", pid);
    d = opendir(path);
    if (!d) return 0;
    while ((e = readdir(d))) {
        char *end;
        unsigned long tid;
        FILE *f;
        if (!isdigit((unsigned char)e->d_name[0])) continue;
        tid = strtoul(e->d_name, &end, 10);
        if (*end) continue;
        snprintf(path, sizeof(path), "/proc/%d/task/%lu/status", pid, tid);
        f = fopen(path, "r");
        if (!f) { all = 0; break; }
        state = '?';
        while (fgets(line, sizeof(line), f))
            if (sscanf(line, "State: %c", &state) == 1) break;
        fclose(f);
        if (state != 'T') { all = 0; break; }
        s->count++; s->sum += tid; s->sum2 += (uint64_t)tid * tid;
    }
    closedir(d);
    return all && s->count;
}
int all_threads_stopped(pid_t pid)
{
    struct snapshot a, b;
    if (!stopped_snapshot(pid, &a)) return 0;
    if (!stopped_snapshot(pid, &b)) return 0;
    return a.count == b.count && a.sum == b.sum && a.sum2 == b.sum2;
}

/* Field 22 after the final ')' in /proc/PID/stat: protects against PID reuse. */
uint64_t process_start_ticks(pid_t pid)
{
    char path[128], line[4096], *p, *save, *word;
    FILE *f;
    int field=3;
    snprintf(path,sizeof(path),"/proc/%d/stat",pid);
    f=fopen(path,"r");
    if(!f) return 0;
    p=fgets(line,sizeof(line),f); fclose(f);
    if(!p || !(p=strrchr(line,')'))) return 0;
    for(word=strtok_r(p+1," ",&save); word; word=strtok_r(NULL," ",&save),field++)
        if(field==22) return strtoull(word,NULL,10);
    return 0;
}
