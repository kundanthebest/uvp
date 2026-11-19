// SPDX-License-Identifier: GPL-2.0-only
/* One read-only native NVMe Identify Controller from a non-leader thread. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/nvme_ioctl.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>

struct test {
    int fd, status;
    atomic_bool done;
};

static void *identify(void *arg)
{
    struct test *t = arg;
    unsigned char data[4096] = {0};
    struct nvme_admin_cmd cmd = {
        .opcode = 0x06, .addr = (uintptr_t)data, .data_len = sizeof(data),
        .cdw10 = 1, /* CNS = Identify Controller */
    };
    printf("tgid=%d tid=%d\n", getpid(), gettid());
    fflush(stdout);
    t->status = ioctl(t->fd, NVME_IOCTL_ADMIN_CMD, &cmd);
    if (t->status < 0) perror("Identify Controller");
    atomic_store(&t->done, 1);
    return NULL;
}

int main(int argc, char **argv)
{
    struct test t = {0};
    pthread_t thread;
    if (argc != 2 || (t.fd = open(argv[1], O_RDONLY | O_CLOEXEC)) < 0) {
        perror("open controller"); return 1;
    }
    if (pthread_create(&thread, NULL, identify, &t)) return 1;
    /* A sibling repeatedly reaches sys_exit while the ioctl is in flight. */
    while (!atomic_load(&t.done)) sched_yield();
    if (pthread_join(thread, NULL)) return 1;
    close(t.fd);
    return t.status != 0;
}
