// SPDX-License-Identifier: GPL-2.0-only
/* Author: Kundan Kumar <kundan.kumar@samsung.com>
 * One process, one test, one event. Attach before running migrate.sh.
 * IMPORTANT: a guest command executes AFTER SIGCONT; guest CPUs might remain
 * migration-paused until destination activation. SIGCONT is NOT NVMe Resume.
 */
#define _GNU_SOURCE
#ifdef UVP_NO_BPF
#include "no_bpf_test.h"
#else
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#endif
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include "uvp.h"
#include "process.h"

#ifndef UVP_INSTALLED_BPF
#define UVP_INSTALLED_BPF "/usr/local/lib/uvp-live-fio/hooks.bpf.o"
#endif
static volatile sig_atomic_t interrupted;
static bool verbose;
static void on_signal(int s) { interrupted = s; }
static const char *symbols[] = {NULL, "nvmevf_cmd_suspend_device",
    "nvmevf_cmd_get_ctrl_state", "nvmevf_cmd_set_ctrl_state",
    "nvmevf_cmd_resume_device", NULL};
static const char *phases[] = {NULL, "suspend", "get-state", "set-state", "resume",
    "custom-command"};
static int print_bpf(enum libbpf_print_level level, const char *fmt, va_list args)
{
    if (level == LIBBPF_DEBUG && !verbose) return 0;
    return vfprintf(stderr, fmt, args);
}
struct app {
    struct uvp_config cfg;
    struct uvp_event event;
    struct bpf_object *obj;
    struct bpf_link *links[6];
    struct ring_buffer *rb;
    int config_fd, control_fd, stats_fd, pidfd, lockfd, wdpipe;
    pid_t pid, worker, watchdog, mock;
    unsigned int timeout_s, action_timeout_s, hold_ms, hold_timeout_s;
    unsigned int host_argc;
    char *host_action[65];
    const char *symbol, *bpf_path, *ready_path;
    char **action;
    bool got_event, released, own_stop, selftest, interactive, host_ran;
};
static unsigned int number(const char *s, unsigned int min, unsigned int max)
{
    char *end;
    unsigned long n;
    errno = 0; n = strtoul(s, &end, 0);
    if (errno || !*s || *end || n < min || n > max) {
        fprintf(stderr, "Invalid number: %s\n", s); exit(2);
    }
    return (unsigned int)n;
}
static void usage(FILE *f)
{
    fprintf(f, "uvp-daemon --pid PID --case 1|2|3|4|5 --controller /dev/nvmeN\n"
        "  [--cntlid ID] [--phase-symbol NAME] [--bpf FILE] [--timeout SEC]\n"
        "  [--action-timeout SEC] [--hold-ms MS] [--ready-file FILE] [--debug]\n"
        "  [--control-stdin --hold-timeout SEC]\n"
        "  [--host-action-program FILE --host-action-arg ARG ...]\n"
        "  case 5: --opcode BYTE --queue admin|io\n"
        "    [--nsid VALUE --nsid-mask MASK] [--cdw10 VALUE --cdw10-mask MASK]\n"
        "    [--cdw11 VALUE --cdw11-mask MASK] (masks default to 0: wildcard)\n"
        "  -- /absolute/action-script [args...]\n\n"
        "--selftest --case N -- /bin/true: synthetic event, no BPF/NVMe/VM.\n"
        "Case 5 without --phase-symbol gates synchronous native NVMe passthrough\n"
        "ioctls only; no io_uring, compat ioctls, or background I/O support.\n"
        "Case 5 with a symbol requires an audited synchronous int-return wrapper.\n"
        "Cases 1-4 require --cntlid; case 5 uses its explicit masks instead.\n"
        "Guest action is QUEUED while stopped, EXECUTED after SIGCONT.\n");
}
static int parse(struct app *a, int argc, char **argv)
{
    int x;
    const char *controller = NULL;
    bool have_opcode = false, have_queue = false, custom_options = false;
    enum {PID=1000, CASE, CONTROLLER, CNTLID, SYMBOL, BPF, TIMEOUT, ACTIONTIME,
          HOLD, READY, DEBUG, SELFTEST, INTERACTIVE, HOLDTIME, HOSTPROGRAM, HOSTARG,
          OPCODE, QUEUE, NSID, NSID_MASK, CDW10, CDW10_MASK, CDW11, CDW11_MASK};
    static const struct option opts[] = {
        {"pid",1,0,PID}, {"case",1,0,CASE}, {"controller",1,0,CONTROLLER},
        {"cntlid",1,0,CNTLID}, {"phase-symbol",1,0,SYMBOL}, {"bpf",1,0,BPF},
        {"timeout",1,0,TIMEOUT}, {"action-timeout",1,0,ACTIONTIME},
        {"hold-ms",1,0,HOLD}, {"ready-file",1,0,READY}, {"debug",0,0,DEBUG},
        {"selftest",0,0,SELFTEST}, {"control-stdin",0,0,INTERACTIVE},
        {"hold-timeout",1,0,HOLDTIME}, {"host-action-program",1,0,HOSTPROGRAM},
        {"host-action-arg",1,0,HOSTARG},
        {"opcode",1,0,OPCODE}, {"queue",1,0,QUEUE},
        {"nsid",1,0,NSID}, {"nsid-mask",1,0,NSID_MASK},
        {"cdw10",1,0,CDW10}, {"cdw10-mask",1,0,CDW10_MASK},
        {"cdw11",1,0,CDW11}, {"cdw11-mask",1,0,CDW11_MASK},
        {"help",0,0,'h'}, {0,0,0,0}
    };
    a->timeout_s = 300; a->action_timeout_s = 300; a->hold_ms = 200;
    a->cfg.cntlid = UINT_MAX; a->hold_timeout_s = 60;
    while ((x=getopt_long(argc,argv,"+h",opts,NULL)) != -1) {
        switch (x) {
        case PID: a->pid = number(optarg,2,INT_MAX); break;
        case CASE: a->cfg.testcase = number(optarg,1,5); break;
        case CONTROLLER: controller = optarg; break;
        case CNTLID: a->cfg.cntlid = number(optarg,0,65535); break;
        case SYMBOL: a->symbol = optarg; break;
        case BPF: a->bpf_path = optarg; break;
        case TIMEOUT: a->timeout_s = number(optarg,1,86400); break;
        case ACTIONTIME: a->action_timeout_s = number(optarg,1,86400); break;
        case HOLD: a->hold_ms = number(optarg,0,5000); break;
        case READY: a->ready_path = optarg; break;
        case DEBUG: verbose = true; a->cfg.debug = 1; break;
        case SELFTEST: a->selftest = true; break;
        case INTERACTIVE: a->interactive = true; break;
        case HOLDTIME: a->hold_timeout_s = number(optarg,1,600); break;
        case HOSTPROGRAM:
            if (a->host_argc || optarg[0] != '/') return -1;
            a->host_action[a->host_argc++] = optarg; break;
        case HOSTARG:
            if (!a->host_argc || a->host_argc >= 64) return -1;
            a->host_action[a->host_argc++] = optarg; break;
        case OPCODE:
            a->cfg.opcode = number(optarg,0,255);
            have_opcode = custom_options = true; break;
        case QUEUE:
            if (!strcmp(optarg,"admin")) a->cfg.queue = UVP_QUEUE_ADMIN;
            else if (!strcmp(optarg,"io")) a->cfg.queue = UVP_QUEUE_IO;
            else return -1;
            have_queue = custom_options = true; break;
        case NSID: a->cfg.nsid = number(optarg,0,UINT_MAX); custom_options=true; break;
        case NSID_MASK: a->cfg.nsid_mask = number(optarg,0,UINT_MAX); custom_options=true; break;
        case CDW10: a->cfg.cdw10 = number(optarg,0,UINT_MAX); custom_options=true; break;
        case CDW10_MASK: a->cfg.cdw10_mask = number(optarg,0,UINT_MAX); custom_options=true; break;
        case CDW11: a->cfg.cdw11 = number(optarg,0,UINT_MAX); custom_options=true; break;
        case CDW11_MASK: a->cfg.cdw11_mask = number(optarg,0,UINT_MAX); custom_options=true; break;
        case 'h': usage(stdout); exit(0);
        default: return -1;
        }
    }
    if (!a->cfg.testcase || optind >= argc) return -1;
    if (a->cfg.testcase == TC_CUSTOM) {
        if (!have_opcode || !have_queue) {
            fprintf(stderr,"Case 5 requires an explicit opcode and queue.\n");
            return -1;
        }
        if (a->cfg.cntlid == UINT_MAX) a->cfg.cntlid = 0;
    } else if (custom_options) {
        fprintf(stderr,"Command selectors require case 5.\n"); return -1;
    }
    a->action = argv + optind;
    if (a->host_argc && !a->interactive) return -1;
#ifdef UVP_NO_BPF
    if (!a->selftest) {
        fprintf(stderr,"This test-only binary cannot load BPF or target QEMU.\n");
        return -1;
    }
#endif
    if (!a->symbol) a->symbol = symbols[a->cfg.testcase];
    a->cfg.use_wrapper = a->symbol != NULL;
    if (!a->bpf_path)
        a->bpf_path = access("bin/hooks.bpf.o", R_OK) == 0 ?
            "bin/hooks.bpf.o" : UVP_INSTALLED_BPF;
    if (!a->selftest) {
        char extra;
        if (geteuid() != 0 || !a->pid || !controller ||
            a->cfg.cntlid == UINT_MAX ||
            sscanf(controller,"/dev/nvme%u%c", &a->cfg.ctrl_instance,&extra)!=1) {
            fprintf(stderr,"Need root, QEMU host TGID, /dev/nvmeN and CNTLID.\n");
            return -1;
        }
    } else if (a->pid) {
        fprintf(stderr,"--selftest cannot target an existing process.\n"); return -1;
    }
    return 0;
}
static int on_event(void *arg, void *data, size_t size)
{
    struct app *a = arg;
    const struct uvp_event *e = data;
    if (size != sizeof(*e) || e->version != UVP_VERSION ||
        e->tgid != (unsigned int)a->pid || e->testcase != a->cfg.testcase ||
        e->epoch != a->cfg.epoch || e->cntlid != a->cfg.cntlid ||
        e->ctrl_instance != a->cfg.ctrl_instance || a->got_event) return 0;
    a->event = *e; a->got_event = true;
    printf("EVENT case=%u phase=%s tgid=%u tid=%u ctrl=nvme%u cntlid=%u "
        "submit=%u complete=%u syscall=%lld ret=%lld wrapper_rc=%d "
        "status=0x%x later_mask=0x%x reason=%u signal_rc=%d opcode=0x%x nsid=%u\n",
        e->testcase,phases[e->testcase],e->tgid,e->tid,e->ctrl_instance,e->cntlid,
        e->submitted,e->completed,(long long)e->syscall_id,(long long)e->syscall_ret,
        e->wrapper_rc,e->status,e->later_mask,e->reason,e->signal_rc,
        e->opcode,e->nsid);
    printf("TIMES kernel_mono_ns submit=%llu complete=%llu wrapper=%llu exit=%llu\n",
        (unsigned long long)e->submit_ns,(unsigned long long)e->complete_ns,
        (unsigned long long)e->wrapper_ns,(unsigned long long)e->exit_ns);
    return 0;
}
static int attach_one(struct app *a, int n, const char *name,
                      const char *kind, const char *target)
{
    struct bpf_program *p = bpf_object__find_program_by_name(a->obj,name);
    if (!p) return -1;
    if (!strcmp(kind,"entry")) a->links[n]=bpf_program__attach_kprobe(p,false,target);
    else if (!strcmp(kind,"return")) a->links[n]=bpf_program__attach_kprobe(p,true,target);
    else if (!strcmp(kind,"raw")) a->links[n]=bpf_program__attach_raw_tracepoint(p,target);
    else a->links[n]=bpf_program__attach_tracepoint(p,"raw_syscalls",target);
    if (!a->links[n] || libbpf_get_error(a->links[n])) {
        a->links[n]=NULL;
        fprintf(stderr,"Attach failed: %s -> %s. Verify symbol/BTF/permissions.\n",name,target);
        return -1;
    }
    return 0;
}
static int load_bpf(struct app *a)
{
    struct rlimit r = {RLIM_INFINITY,RLIM_INFINITY};
    setrlimit(RLIMIT_MEMLOCK,&r);
    libbpf_set_print(print_bpf);
    a->obj = bpf_object__open_file(a->bpf_path,NULL);
    if (!a->obj || libbpf_get_error(a->obj)) { a->obj=NULL; return -1; }
    if (bpf_object__load(a->obj)) return -1;
    a->config_fd=bpf_object__find_map_fd_by_name(a->obj,"config");
    a->control_fd=bpf_object__find_map_fd_by_name(a->obj,"control");
    a->stats_fd=bpf_object__find_map_fd_by_name(a->obj,"stats");
    if (a->config_fd<0 || a->control_fd<0 || a->stats_fd<0) return -1;
    if (attach_one(a,0,"on_enter","trace","sys_enter") ||
        (a->cfg.use_wrapper && attach_one(a,1,"phase_enter","entry",a->symbol)) ||
        (a->cfg.use_wrapper && attach_one(a,2,"phase_return","return",a->symbol)) ||
        attach_one(a,3,"on_init","entry","nvme_init_request") ||
        attach_one(a,4,"on_complete","raw","nvme_complete_rq") ||
        attach_one(a,5,"on_exit","trace","sys_exit")) return -1;
    a->rb=ring_buffer__new(bpf_object__find_map_fd_by_name(a->obj,"events"),
                          on_event,a,NULL);
    return a->rb ? 0 : -1;
}
static void disarm(struct app *a)
{
    unsigned int zero=0;
    a->cfg.enabled=0;
    if (a->config_fd>=0 && bpf_map_update_elem(a->config_fd,&zero,&a->cfg,BPF_ANY))
        fprintf(stderr,"WARN: cannot disarm config map: %s\n",strerror(errno));
}
static int stop_intent(struct app *a)
{
    struct uvp_control c = {};
    unsigned int zero=0;
    if (a->selftest) return a->own_stop;
    return a->control_fd>=0 && !bpf_map_lookup_elem(a->control_fd,&zero,&c) &&
           c.request_ns && c.signal_rc==0;
}
static int write_pipe_byte(int fd, char byte)
{
    ssize_t n;
    do {
        n = write(fd, &byte, 1);
    } while (n < 0 && errno == EINTR);
    if (n == 1) return 0;
    if (n == 0) errno = EIO;
    return -1;
}
static int close_watchdog_pipe(struct app *a)
{
    int rc = 0;
    if (a->wdpipe < 0) return 0;
    /* Without a confirmed release, EOF lets the watchdog recover a stop. */
    if (a->released && write_pipe_byte(a->wdpipe, 'D')) {
        perror("watchdog release notification");
        rc = -1;
    }
    close(a->wdpipe);
    a->wdpipe = -1;
    return rc;
}
/* Independent bounded-hold watchdog. Release does not undo a host action.
 * It never kills QEMU. It does NOT recover kernel/hardware hangs. */
static int start_watchdog(struct app *a)
{
    int p[2];
    if (pipe2(p,O_CLOEXEC)) return -1;
    a->watchdog=fork();
    if (a->watchdog<0) { close(p[0]); close(p[1]); return -1; }
    if (!a->watchdog) {
        uint64_t intent_at=0;
        bool parent_dead=false;
        close(p[1]);
        signal(SIGINT,SIG_IGN); signal(SIGTERM,SIG_IGN);
        for (;;) {
            struct pollfd q={.fd=p[0],.events=POLLIN|POLLHUP};
            char c=0;
            poll(&q,1,100);
            if (q.revents) {
                ssize_t n=read(p[0],&c,1);
                if (n==1 && c=='D') _exit(0);
                if (!n) parent_dead=true;
            }
            if (pidfd_exited(a->pidfd)) _exit(0);
            /* Mock event is generated after fork: parent sends I explicitly. */
            if (a->selftest && q.revents && c=='I') a->own_stop=true;
            if (stop_intent(a) && !intent_at) intent_at=now_ms();
            if (parent_dead || (intent_at && now_ms()-intent_at>(a->interactive ? (uint64_t)a->hold_timeout_s*1000+5000 : 10000))) {
                disarm(a);
                if (intent_at) {
                    uint64_t until=now_ms()+5000;
                    while (!all_threads_stopped(a->pid) && now_ms()<until &&
                           !pidfd_exited(a->pidfd)) sleep_ms(20);
                    fprintf(stderr,"WATCHDOG: release requested stop; run INVALID\n");
                    signal_pidfd(a->pidfd,SIGCONT);
                }
                _exit(3);
            }
        }
    }
    close(p[0]); a->wdpipe=p[1]; return 0;
}
static int wait_for_stop(struct app *a)
{
    uint64_t until=now_ms()+5000;
    while (!interrupted && now_ms()<until && !pidfd_exited(a->pidfd)) {
        if (all_threads_stopped(a->pid)) {
            sleep_ms(20);
            if (all_threads_stopped(a->pid)) return 0;
        }
        sleep_ms(10);
    }
    return -1;
}
/* Fork now, but worker cannot execute the guest command before release byte. */
static int queue_action(struct app *a, int *releasefd)
{
    int p[2];
    if (pipe2(p,O_CLOEXEC)) return -1;
    a->worker=fork();
    if (a->worker<0) { close(p[0]); close(p[1]); return -1; }
    if (!a->worker) {
        char byte, value[40];
        close(p[1]);
        if (a->wdpipe>=0) close(a->wdpipe);
        setpgid(0,0);
        signal(SIGINT,SIG_DFL); signal(SIGTERM,SIG_DFL);
        prctl(PR_SET_PDEATHSIG,SIGKILL);
        if (read(p[0],&byte,1)!=1 || byte!='G') _exit(125);
        close(p[0]);
        snprintf(value,sizeof(value),"%u",a->cfg.testcase);
        setenv("UVP_TESTCASE",value,1);
        snprintf(value,sizeof(value),"%d",a->pid);
        setenv("UVP_QEMU_TGID",value,1);
        snprintf(value,sizeof(value),"%llu",(unsigned long long)a->cfg.epoch);
        setenv("UVP_EPOCH",value,1);
        puts("ACTION_EXEC: QEMU released; guest command may now wait for guest readiness");
        /* Keep action output off the machine-control stdout stream. */
        if (dup2(STDERR_FILENO,STDOUT_FILENO)<0) _exit(125);
        execvp(a->action[0],a->action);
        perror("exec action"); _exit(127);
    }
    close(p[0]); setpgid(a->worker,a->worker);
    *releasefd=p[1];
    printf("ACTION_QUEUED worker=%d (not yet executed in guest)\n",a->worker);
    return 0;
}
/* New UI protocol: only literal commands, never shell text or argv from stdin.
 * EOF is an owner disconnect. The daemon releases only its pidfd target. */
static int read_control(void)
{
    static char line[32];
    static size_t used;
    for (;;) {
        struct pollfd p={.fd=STDIN_FILENO,.events=POLLIN|POLLHUP};
        char c;
        int r=poll(&p,1,0);
        if (r<0) return errno==EINTR ? 0 : -1;
        if (!r) return 0;
        if (read(STDIN_FILENO,&c,1)!=1) return -1;
        if (c=='\n') {
            line[used]=0; used=0;
            if (!strcmp(line,"resume")) return 1;
            if (!strcmp(line,"action")) return 2;
            if (!strcmp(line,"cancel")) return 3;
            return -1;
        }
        if (used>=sizeof(line)-1) return -1;
        line[used++]=c;
    }
}
static int await_action(struct app *a)
{
    uint64_t deadline=now_ms()+(uint64_t)a->action_timeout_s*1000;
    int status;
    for (;;) {
        pid_t r;
        /* Deadline BEFORE wait and BEFORE accepting a successful completion. */
        if (a->interactive) {
            int c=read_control();
            if (c<0 || c==3) interrupted=SIGTERM;
            else if (c) puts("CONTROL_REJECTED: action is busy");
        }
        if (interrupted || now_ms()>=deadline) {
            fprintf(stderr,"FAIL: action interrupted/timed out; no success inferred\n");
            return -1;
        }
        r=waitpid(a->worker,&status,WNOHANG);
        if (r==a->worker) {
            a->worker=0;
            if (now_ms()>=deadline || !WIFEXITED(status) || WEXITSTATUS(status)) {
                fprintf(stderr,"FAIL: action failed or completed after deadline\n");
                return -1;
            }
            return 0;
        }
        if (r<0 && errno!=EINTR) return -1;
        sleep_ms(20);
    }
}
static int interactive_hold(struct app *a)
{
    uint64_t until=now_ms()+(uint64_t)a->hold_timeout_s*1000;
    printf("HOLD_READY timeout_s=%u\n",a->hold_timeout_s);
    while (!interrupted && now_ms()<until && !pidfd_exited(a->pidfd)) {
        int c=read_control();
        if (c<0 || c==3) {
            fprintf(stderr,"FAIL: control disconnected/cancelled\n"); return -1;
        }
        if (!all_threads_stopped(a->pid)) {
            fprintf(stderr,"FAIL: QEMU left owned hold unexpectedly\n"); return -1;
        }
        if (c==1) return 0;
        if (c==2) {
            if (!a->host_argc || a->host_ran) {
                puts("CONTROL_REJECTED: no host action or already executed");
                continue;
            }
            a->host_ran=true;
            puts("HOST_ACTION_STARTED");
            a->worker=fork();
            if (a->worker<0) return -1;
            if (!a->worker) {
                pid_t parent=getppid();
                if (a->wdpipe>=0) close(a->wdpipe);
                setpgid(0,0);
                signal(SIGINT,SIG_DFL); signal(SIGTERM,SIG_DFL);
                prctl(PR_SET_PDEATHSIG,SIGKILL);
                if (getppid()!=parent) _exit(125);
                int nullfd=open("/dev/null",O_RDONLY);
                if (nullfd<0 || dup2(nullfd,STDIN_FILENO)<0) _exit(125);
                close(nullfd);
                char value[40];
                snprintf(value,sizeof(value),"%u",a->cfg.testcase);
                setenv("UVP_TESTCASE",value,1);
                snprintf(value,sizeof(value),"%d",a->pid);
                setenv("UVP_QEMU_TGID",value,1);
                snprintf(value,sizeof(value),"%llu",(unsigned long long)a->cfg.epoch);
                setenv("UVP_EPOCH",value,1);
                if (dup2(STDERR_FILENO,STDOUT_FILENO)<0) _exit(125);
                execv(a->host_action[0],a->host_action);
                perror("exec host action"); _exit(127);
            }
            setpgid(a->worker,a->worker);
            /* Bound worker to remaining hold time, not a fresh hold interval. */
            unsigned int saved=a->action_timeout_s;
            unsigned int remaining=(until>now_ms()) ? (until-now_ms())/1000 : 0;
            if (!remaining) return -1;
            if (a->action_timeout_s>remaining) a->action_timeout_s=remaining;
            int rc=await_action(a);
            a->action_timeout_s=saved;
            if (rc || now_ms()>=until || !all_threads_stopped(a->pid)) {
                fprintf(stderr,"HOST_ACTION_FAILED\n"); return -1;
            }
            puts("HOST_ACTION_DONE");
        }
        sleep_ms(20);
    }
    fprintf(stderr,"FAIL: hold deadline/interruption/target exit\n");
    return -1;
}
static void cleanup(struct app *a)
{
    disarm(a);
    if (a->worker>0) {
        /* End the launched host-action group before resuming QEMU. A reset
         * already accepted by hardware cannot be undone; a worker stuck in
         * uninterruptible kernel sleep can outlive this bounded cleanup. */
        kill(-a->worker,SIGKILL); kill(a->worker,SIGKILL);
        /* Bounded reap: do not block forever on a worker in kernel D state. */
        uint64_t until=now_ms()+1000;
        int status;
        pid_t reaped;
        do {
            reaped=waitpid(a->worker,&status,WNOHANG);
            if (reaped==a->worker || (reaped<0 && errno==ECHILD)) break;
            sleep_ms(20);
        } while (now_ms()<until);
        if (reaped==0 || (reaped<0 && errno!=ECHILD))
            fprintf(stderr,"WARN: action worker did not exit; inspect host/device state\n");
    }
    if (!a->released && (a->own_stop || stop_intent(a))) {
        /* Avoid leaving a paused QEMU behind on ordinary errors/interrupts. */
        wait_for_stop(a);
        fprintf(stderr,"CLEANUP: SIGCONT only to our registered target; run failed\n");
        if (signal_pidfd(a->pidfd,SIGCONT)) perror("cleanup SIGCONT");
        else a->released=true;
    }
    close_watchdog_pipe(a);
    if (a->watchdog>0) waitpid(a->watchdog,NULL,0);
    if (a->mock>0) { signal_pidfd(a->pidfd,SIGKILL); waitpid(a->mock,NULL,0); }
    if (a->stats_fd>=0) {
        unsigned int i; __u64 value;
        const char *names[]={"syscalls","wrappers","submits","completions","events",
            "read_fail","map_fail","ring_fail","signal_fail"};
        for(i=0;i<S_MAX;i++) if(!bpf_map_lookup_elem(a->stats_fd,&i,&value))
            printf("STAT %s=%llu\n",names[i],(unsigned long long)value);
    }
    ring_buffer__free(a->rb);
    for (int i=0;i<6;i++) bpf_link__destroy(a->links[i]);
    bpf_object__close(a->obj);
    if (a->pidfd>=0) close(a->pidfd);
    if (a->lockfd>=0) close(a->lockfd);
}
int main(int argc,char **argv)
{
    struct app a = {.config_fd=-1,.control_fd=-1,.stats_fd=-1,.pidfd=-1,
                    .lockfd=-1,.wdpipe=-1};
    uint64_t deadline;
    unsigned int zero=0;
    int result=1, releasefd=-1;
    char lockpath[160];
    setvbuf(stdout,NULL,_IOLBF,0); setvbuf(stderr,NULL,_IOLBF,0);
    if (parse(&a,argc,argv)) { usage(stderr); return 2; }
    signal(SIGINT,on_signal); signal(SIGTERM,on_signal); signal(SIGHUP,on_signal);
    signal(SIGPIPE,SIG_IGN);
    if (a.selftest) {
        a.mock=fork();
        if (!a.mock) { for (;;) pause(); }
        if (a.mock<0) return 1;
        a.pid=a.mock; a.cfg.cntlid=1;
        puts("SELFTEST: synthetic event only; no BPF, NVMe, QEMU or guest fio");
    }
    a.pidfd=open_pidfd(a.pid);
    if (a.pidfd<0 || check_process(a.pid) || pidfd_exited(a.pidfd) ||
        all_threads_stopped(a.pid)) {
        fprintf(stderr,"Invalid, exited, traced, or already stopped target\n"); goto out;
    }
    if (a.selftest) snprintf(lockpath,sizeof(lockpath),"/tmp/uvp-fio-%u-%d.lock",getuid(),a.pid);
    else {
        if (mkdir("/run/uvp-live-fio",0700) && errno!=EEXIST) goto out;
        snprintf(lockpath,sizeof(lockpath),"/run/uvp-live-fio/%d.lock",a.pid);
    }
    a.lockfd=open(lockpath,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0600);
    if (a.lockfd<0 || flock(a.lockfd,LOCK_EX|LOCK_NB)) {
        fprintf(stderr,"Another daemon owns this target or lock failed\n"); goto out;
    }
    a.cfg.start_ticks=process_start_ticks(a.pid);
    a.cfg.clock_ticks=(unsigned int)sysconf(_SC_CLK_TCK);
    if (!a.cfg.start_ticks || !a.cfg.clock_ticks) goto out;
    a.cfg.tgid=a.pid; a.cfg.epoch=now_ms()*1000000ULL+(unsigned int)getpid();
    if (!a.selftest && load_bpf(&a)) {
        fprintf(stderr,"BPF load/attach failed; no target was stopped\n"); goto out;
    }
    if (start_watchdog(&a)) goto out;
    a.cfg.enabled=1;
    if (!a.selftest && bpf_map_update_elem(a.config_fd,&zero,&a.cfg,BPF_ANY)) goto out;
    printf("READY pid=%d case=%u phase=%s wrapper=%s\n",a.pid,a.cfg.testcase,
           phases[a.cfg.testcase],a.symbol ? a.symbol : "native-nvme-ioctl");
    if (a.ready_path) {
        int fd=open(a.ready_path,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);
        if(fd<0) { perror("ready-file (remove stale file first)"); goto out; }
        dprintf(fd,"pid=%d case=%u epoch=%llu\n",a.pid,a.cfg.testcase,
                (unsigned long long)a.cfg.epoch); close(fd);
    }
    deadline=now_ms()+(uint64_t)a.timeout_s*1000;
    if (a.selftest) {
        a.event=(struct uvp_event){.version=UVP_VERSION,.testcase=a.cfg.testcase,
            .tgid=a.pid,.tid=a.pid,.epoch=a.cfg.epoch,
            .ctrl_instance=a.cfg.ctrl_instance,.cntlid=a.cfg.cntlid};
        if (write_pipe_byte(a.wdpipe, 'I')) {
            perror("watchdog stop-intent notification"); goto out;
        }
        a.own_stop=true;
        if (signal_pidfd(a.pidfd,SIGSTOP)) goto out;
        on_event(&a,&a.event,sizeof(a.event));
    }
    while(!a.got_event && !interrupted && now_ms()<deadline && !pidfd_exited(a.pidfd)) {
        if (a.interactive) {
            int command=read_control();
            if (command<0 || command==3) { interrupted=SIGTERM; break; }
            if (command) puts("CONTROL_REJECTED: checkpoint not held");
        }
        int r=ring_buffer__poll(a.rb,50);
        if(r<0 && r!=-EINTR) goto out;
        struct uvp_control c={};
        if(!bpf_map_lookup_elem(a.control_fd,&zero,&c) && c.fired && !c.request_ns) {
            __u64 lost=0; unsigned int key=S_RING_FAIL;
            bpf_map_lookup_elem(a.stats_fd,&key,&lost);
            if(lost) { fprintf(stderr,"FAIL: ring buffer reservation failed\n"); goto out; }
        }
    }
    if (interrupted || now_ms()>=deadline || !a.got_event) {
        fprintf(stderr,"FAIL: no eligible checkpoint before interruption/timeout/exit\n"); goto out;
    }
    if(a.event.reason || a.event.signal_rc) {
        fprintf(stderr,"FAIL: checkpoint rejected; later_mask means a coalesced transition\n"); goto out;
    }
    a.own_stop=true;
    if(wait_for_stop(&a)) { fprintf(stderr,"FAIL: no confirmed group stop\n"); goto out; }
    printf("STOP_CONFIRMED pid=%d host_mono_ms=%llu\n",a.pid,(unsigned long long)now_ms());
    if (a.interactive) {
        if (interactive_hold(&a)) goto out;
    } else {
        sleep_ms(a.hold_ms);
        if (now_ms()>=deadline) goto out;
    }
    if(interrupted || !all_threads_stopped(a.pid)) goto out;
    if(queue_action(&a,&releasefd)) goto out;
    if(interrupted || (!a.interactive && now_ms()>=deadline)) goto out;
    disarm(&a);
    if(signal_pidfd(a.pidfd,SIGCONT)) goto out;
    a.released=true;
    printf("SIGCONT pid=%d host_mono_ms=%llu (guest may still be migration-paused)\n",
           a.pid,(unsigned long long)now_ms());
    if (close_watchdog_pipe(&a)) goto out;
    if (write_pipe_byte(releasefd, 'G')) goto out;
    close(releasefd); releasefd=-1;
    if(await_action(&a)) goto out;
    puts("ACTION_ACKNOWLEDGED: inspect guest logs; this is NOT a migration/data-integrity PASS");
    result=0;
out:
    if(releasefd>=0) close(releasefd);
    cleanup(&a);
    if(result) fprintf(stderr,"RUN_FAILED (no success inferred from missing evidence)\n");
    return interrupted ? 128+interrupted : result;
}
