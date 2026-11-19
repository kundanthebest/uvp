/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef UVP_PROCESS_H
#define UVP_PROCESS_H
#include <stdint.h>
#include <sys/types.h>
uint64_t now_ms(void);
void sleep_ms(unsigned int ms);
int open_pidfd(pid_t pid);
int signal_pidfd(int fd, int signal);
int pidfd_exited(int fd);
/* 1 iff two consecutive task snapshots contain the same TIDs, all state T.
 * Not ptrace; requires exclusive stop/resume ownership during the experiment.
 */
int all_threads_stopped(pid_t pid);
int check_issuer_access(void);
int check_process(pid_t pid);
uint64_t process_start_ticks(pid_t pid);
#endif
