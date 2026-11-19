// SPDX-License-Identifier: GPL-2.0-only
/* Author: Kundan Kumar <kundan.kumar@samsung.com>
 * Three semantic hooks plus syscall guard and a logical-operation wrapper.
 * The wrapper pair prevents Get's header read from meaning "full state done".
 * Change the wrapper SYMBOL in config, not this code, for a renamed driver.
 */
#include <linux/bpf.h>
#include <linux/errno.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include "uvp.h"
#if !defined(__TARGET_ARCH_x86)
#error "Port the register adapter before building for a non-x86-64 host"
#endif

/* CO-RE flavor types: offsets/sizes are relocated using the running BTF. */
struct pt_regs___uvp { unsigned long di, si, ax, sp, cs, orig_ax; }
    __attribute__((preserve_access_index));
struct task_struct___uvp {
    struct task_struct___uvp *group_leader;
    void *mm, *stack;
    unsigned int flags, ptrace;
    __u64 start_boottime;
} __attribute__((preserve_access_index));
struct request_queue___uvp { int unused; }
    __attribute__((preserve_access_index));
struct request___uvp { struct request_queue___uvp *q; }
    __attribute__((preserve_access_index));
struct nvme_ctrl___uvp {
    int instance;
    struct request_queue___uvp *admin_q;
} __attribute__((preserve_access_index));
struct nvme_request___uvp {
    void *cmd;
    struct nvme_ctrl___uvp *ctrl;
    __u8 flags;
    __u16 status;
} __attribute__((preserve_access_index));
struct enter_ctx { __u64 common; __s64 id; __u64 args[6]; };
struct exit_ctx { __u64 common; __s64 id, ret; };

#define MAP(name, kind, key_t, val_t, n) \
struct { __uint(type, kind); __uint(max_entries, n); \
         __type(key, key_t); __type(value, val_t); } name SEC(".maps")
MAP(config, BPF_MAP_TYPE_ARRAY, __u32, struct uvp_config, 1);
MAP(control, BPF_MAP_TYPE_ARRAY, __u32, struct uvp_control, 1);
/* The watchdog and the signaling path race to remove the same key. */
MAP(permit, BPF_MAP_TYPE_HASH, __u32, __u32, 1);
/* Userspace looks up this marker using a pidfd for the group leader. */
struct {
    __uint(type, BPF_MAP_TYPE_TASK_STORAGE);
    __uint(map_flags, BPF_F_NO_PREALLOC);
    __type(key, int);
    __type(value, __u64);
} issuers SEC(".maps");
MAP(gates, BPF_MAP_TYPE_HASH, __u64, struct uvp_gate, 1024);
MAP(requests, BPF_MAP_TYPE_HASH, __u64, struct uvp_owner, 128);
MAP(stats, BPF_MAP_TYPE_ARRAY, __u32, __u64, S_MAX);
struct { __uint(type, BPF_MAP_TYPE_RINGBUF); __uint(max_entries, 256 * 1024); }
    events SEC(".maps");

static __always_inline void count(__u32 k)
{
    __u64 *v = bpf_map_lookup_elem(&stats, &k);
    if (v) __sync_fetch_and_add(v, 1);
}
static __always_inline struct uvp_config *active_config(void)
{
    __u32 zero = 0;
    struct uvp_config *c = bpf_map_lookup_elem(&config, &zero);
    return c && c->enabled ? c : 0;
}
/* Only ordinary user tasks are eligible. A worker can borrow an mm. */
static __always_inline int issuer_birth(__u64 owner, __u64 *start_ns,
                                         __u64 *thread_start_ns)
{
    struct task_struct___uvp *task = (void *)bpf_get_current_task(), *leader;
    void *mm;
    unsigned int flags, traced, leader_traced;
    if ((owner >> 32) <= 1 || !(__u32)owner ||
        bpf_core_read(&mm, sizeof(mm), &task->mm) || !mm ||
        bpf_core_read(&flags, sizeof(flags), &task->flags) ||
        (flags & (0x00200000U | 0x00000010U)) || /* PF_KTHREAD | PF_IO_WORKER */
        bpf_core_read(&traced, sizeof(traced), &task->ptrace) || traced ||
        bpf_core_read(&leader, sizeof(leader), &task->group_leader) || !leader ||
        bpf_core_read(&leader_traced, sizeof(leader_traced), &leader->ptrace) ||
        leader_traced ||
        bpf_core_read(start_ns, sizeof(*start_ns), &leader->start_boottime) ||
        bpf_core_read(thread_start_ns, sizeof(*thread_start_ns), &task->start_boottime))
        return 0;
    return *start_ns && *thread_start_ns;
}
/* The kprobe SP must belong to the task's regular kernel stack. An interrupt
 * on an x86 IRQ stack can report an innocent interrupted task as 'current'.
 * Check the saved native user registers to recover the enclosing syscall. */
static __always_inline long task_syscall(struct pt_regs___uvp *ctx)
{
    struct task_struct *task = bpf_get_current_task_btf();
    struct task_struct___uvp *t = (void *)task;
    struct pt_regs___uvp *user_regs = (void *)bpf_task_pt_regs(task);
    unsigned long bottom, sp, cs, id;
    if (!user_regs ||
        bpf_core_read(&bottom, sizeof(bottom), &t->stack) ||
        bpf_core_read(&sp, sizeof(sp), &ctx->sp) ||
        !bottom || sp < bottom || sp > (__u64)user_regs ||
        bpf_core_read(&cs, sizeof(cs), &user_regs->cs) || (cs & 0xffff) != 0x33 ||
        bpf_core_read(&id, sizeof(id), &user_regs->orig_ax))
        return -1;
    return (long)id;
}
static __always_inline struct nvme_request___uvp *nvme_rq(__u64 rq)
{
    return (void *)(rq + bpf_core_type_size(struct request___uvp));
}
static __always_inline void retire(__u64 owner, struct uvp_gate *g)
{
    if (g && g->request) bpf_map_delete_elem(&requests, &g->request);
    bpf_map_delete_elem(&gates, &owner);
}

/* Only a matching synchronous NVMe passthrough needs a gate at sys_enter.
 * A wrapped operation creates its gate lazily at the selected wrapper. */
SEC("tracepoint/raw_syscalls/sys_enter")
int on_enter(struct enter_ctx *ctx)
{
    struct uvp_config *c = active_config();
    struct uvp_gate g = {}, *old;
    __u64 owner = bpf_get_current_pid_tgid();
    __u32 zero = 0;
    struct uvp_control *ctl;
    if (!c) return 0;
    old = bpf_map_lookup_elem(&gates, &owner);
    if (old) retire(owner, old);
    ctl = bpf_map_lookup_elem(&control, &zero);
    if (!ctl || ctl->pid_tgid || c->testcase != TC_CUSTOM || c->use_wrapper ||
        !uvp_custom_ioctl(ctx->id, ctx->args[1], c->queue)) return 0;
    if (!issuer_birth(owner, &g.start_ns, &g.thread_start_ns)) return 0;
    g.entered = g.inside = 1;
    g.cookie = bpf_ktime_get_ns();
    g.syscall_id = ctx->id;
    if (bpf_map_update_elem(&gates, &owner, &g, BPF_NOEXIST)) count(S_MAP_FAIL);
    else count(S_SYSCALL);
    return 0;
}

/* Attached by userspace to one of four existing complete-operation wrappers. */
SEC("kprobe")
int phase_enter(struct pt_regs___uvp *ctx)
{
    __u64 owner = bpf_get_current_pid_tgid();
    __u32 zero = 0;
    struct uvp_gate g = {}, *old;
    struct uvp_config *c = active_config();
    struct uvp_control *ctl = bpf_map_lookup_elem(&control, &zero);
    if (!c || !ctl || (c->testcase == TC_CUSTOM && !c->use_wrapper)) return 0;
    old = bpf_map_lookup_elem(&gates, &owner);
    if (old) { old->tracking_error = 1; return 0; }
    if (ctl->pid_tgid || !issuer_birth(owner, &g.start_ns, &g.thread_start_ns))
        return 0;
    g.syscall_id = task_syscall(ctx);
    if (!uvp_wrapper_syscall(g.syscall_id)) return 0;
    g.entered = g.inside = 1;
    g.cookie = bpf_ktime_get_ns();
    if (bpf_map_update_elem(&gates, &owner, &g, BPF_NOEXIST)) count(S_MAP_FAIL);
    else { count(S_WRAPPER); count(S_SYSCALL); }
    return 0;
}
SEC("kretprobe")
int phase_return(struct pt_regs___uvp *ctx)
{
    __u64 owner = bpf_get_current_pid_tgid(), ret = 0;
    struct uvp_gate *g;
    if (!active_config()) return 0;
    g = bpf_map_lookup_elem(&gates, &owner);
    if (!g || !g->inside) return 0;
    if (bpf_core_read(&ret, sizeof(ret), &ctx->ax)) g->tracking_error = 1;
    g->wrapper_rc = (__s32)ret; /* selected wrapper returns int */
    g->inside = 0;
    g->wrapper_ns = bpf_ktime_get_ns();
    g->returned = 1;
    return 0;
}

/* Hook 1. Capture owner before workqueue/IRQ context changes. */
SEC("kprobe/nvme_init_request")
int on_init(struct pt_regs___uvp *ctx)
{
    struct uvp_config *c = active_config();
    __u32 zero = 0;
    struct uvp_control *ctl;
    struct uvp_gate *g;
    struct uvp_owner ro;
    struct nvme_wire cmd;
    struct nvme_request___uvp *nr;
    struct nvme_ctrl___uvp *ctrl = 0;
    struct request_queue___uvp *q = 0, *aq = 0;
    __u64 owner = bpf_get_current_pid_tgid(), rq = 0, cp = 0;
    __u64 start_ns = 0, thread_start_ns = 0, winner;
    int instance = -1, kind;
    if (!c) return 0;
    g = bpf_map_lookup_elem(&gates, &owner);
    if (!g) return 0;
    if (task_syscall(ctx) != g->syscall_id) return 0;
    if (bpf_core_read(&rq, sizeof(rq), &ctx->di) ||
        bpf_core_read(&cp, sizeof(cp), &ctx->si) || !rq || !cp ||
        bpf_probe_read_kernel(&cmd, sizeof(cmd), (void *)cp)) {
        if (g->entered) g->tracking_error = 1;
        count(S_READ_FAIL); return 0;
    }
    kind = uvp_command_case(&cmd);
    if (c->testcase != TC_CUSTOM &&
        (!kind || (cmd.cdw11 & 0xffff) != c->cntlid)) return 0;
    nr = nvme_rq(rq);
    if (bpf_core_read(&ctrl, sizeof(ctrl), &nr->ctrl) || !ctrl ||
        bpf_core_read(&instance, sizeof(instance), &ctrl->instance) ||
        bpf_core_read(&q, sizeof(q), &((struct request___uvp *)rq)->q) ||
        bpf_core_read(&aq, sizeof(aq), &ctrl->admin_q)) {
        g->tracking_error = 1; count(S_READ_FAIL); return 0;
    }
    if (instance != (int)c->ctrl_instance || !q || !aq) return 0;
    if (c->testcase == TC_CUSTOM) {
        if (!uvp_custom_match(c, &cmd, q == aq)) return 0;
        kind = TC_CUSTOM;
    } else if (q != aq) return 0;
    /* Reject coalesced transitions: e.g. Set and Resume in the SAME syscall. */
    if (g->entered && kind > (int)c->testcase)
        g->later_mask |= 1U << kind;
    if (!g->inside || kind != (int)c->testcase) return 0;
    if (!issuer_birth(owner, &start_ns, &thread_start_ns) ||
        !uvp_same_task_lifetime(g, start_ns, thread_start_ns))
        return 0;
    ctl = bpf_map_lookup_elem(&control, &zero);
    if (!ctl) return 0;
    winner = __sync_val_compare_and_swap(&ctl->pid_tgid, 0, owner);
    if (!winner) {
        struct task_struct___uvp *task = (void *)bpf_get_current_task_btf();
        struct task_struct___uvp *leader = task->group_leader;
        __u64 *marker;
        ctl->start_ns = start_ns;
        ctl->epoch = c->epoch;
        ctl->cookie = g->cookie;
        marker = bpf_task_storage_get(&issuers, (struct task_struct *)leader,
                                      0, BPF_LOCAL_STORAGE_GET_F_CREATE);
        if (!marker) {
            g->tracking_error = 1; count(S_MAP_FAIL); return 0;
        }
        *marker = c->epoch;
    } else if (!uvp_same_submission(ctl, owner, start_ns, g->cookie, c->epoch)) {
        return 0;
    }
    if (g->request) { g->tracking_error = 1; return 0; }
    ro.pid_tgid = owner; ro.cookie = g->cookie; ro.start_ns = start_ns;
    if (bpf_map_update_elem(&requests, &rq, &ro, BPF_NOEXIST)) {
        g->tracking_error = 1; count(S_MAP_FAIL); return 0;
    }
    g->request = rq;
    if (!g->submit_ns) g->submit_ns = bpf_ktime_get_ns();
    g->last_cdw10 = cmd.cdw10; g->last_cdw11 = cmd.cdw11;
    g->last_cdw15 = cmd.cdw15;
    g->last_nsid = cmd.nsid; g->last_opcode = cmd.opcode;
    g->submitted++;
    count(S_SUBMIT);
    return 0;
}

/* Hook 2. Raw tracepoint covers individual AND batched completions. */
SEC("raw_tracepoint/nvme_complete_rq")
int on_complete(struct bpf_raw_tracepoint_args *ctx)
{
    __u64 rq = ctx->args[0];
    struct uvp_owner *ro, saved;
    struct uvp_gate *g;
    struct nvme_request___uvp *nr;
    __u16 status = 0xffff;
    __u8 flags = 0;
    ro = bpf_map_lookup_elem(&requests, &rq);
    if (!ro) return 0;
    saved = *ro;
    g = bpf_map_lookup_elem(&gates, &saved.pid_tgid);
    if (!g || g->cookie != saved.cookie || g->start_ns != saved.start_ns ||
        g->request != rq) goto out;
    nr = nvme_rq(rq);
    if (bpf_core_read(&status, sizeof(status), &nr->status) ||
        bpf_core_read(&flags, sizeof(flags), &nr->flags)) {
        g->tracking_error = 1; count(S_READ_FAIL);
    }
    g->status = status; g->flags = flags;
    if (status || (flags & UVP_CANCELLED)) g->command_error = 1;
    g->request = 0;
    g->complete_ns = bpf_ktime_get_ns();
    __sync_fetch_and_add(&g->completed, 1);
    count(S_COMPLETE);
out:
    /* Conservative: any failing/retrying command invalidates the checkpoint.
     * Never retain a request address after observed completion. */
    bpf_map_delete_elem(&requests, &rq);
    return 0;
}

/* Hook 3. SAME issuing TID. No spin/wait inside BPF. */
SEC("tracepoint/raw_syscalls/sys_exit")
int on_exit(struct exit_ctx *ctx)
{
    struct uvp_config *c = active_config();
    struct uvp_gate *g;
    struct uvp_control *ctl;
    struct uvp_event *e;
    __u64 owner = bpf_get_current_pid_tgid(), start_ns = 0, thread_start_ns = 0;
    __u32 zero = 0, reason;
    if (!c) return 0;
    g = bpf_map_lookup_elem(&gates, &owner);
    if (!g) return 0;
    /* An unrelated invocation of the wrapper must not trigger this device. */
    ctl = bpf_map_lookup_elem(&control, &zero);
    if (!ctl || !g->entered ||
        !uvp_same_submission(ctl, owner, g->start_ns, g->cookie, c->epoch))
        goto out;
    if (c->testcase == TC_CUSTOM && !c->use_wrapper) {
        g->inside = 0; g->returned = 1;
    }
    reason = uvp_gate_reason(g, ctx->ret);
    if (c->testcase == TC_CUSTOM && !c->use_wrapper && ctx->ret != 0)
        reason = BAD_SYSCALL;
    if (g->syscall_id != ctx->id ||
        !issuer_birth(owner, &start_ns, &thread_start_ns) ||
        !uvp_same_task_lifetime(g, start_ns, thread_start_ns))
        reason = BAD_TRACKING;
    if (__sync_val_compare_and_swap(&ctl->fired, 0, 1)) goto out;
    e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) { count(S_RING_FAIL); goto out; }
    __builtin_memset(e, 0, sizeof(*e));
    e->version = UVP_VERSION; e->testcase = c->testcase; e->epoch = ctl->epoch;
    e->tgid = ctl->pid_tgid >> 32; e->tid = (__u32)ctl->pid_tgid;
    e->cookie = ctl->cookie; e->start_ns = ctl->start_ns;
    e->submit_ns = g->submit_ns; e->complete_ns = g->complete_ns;
    e->wrapper_ns = g->wrapper_ns; e->exit_ns = bpf_ktime_get_ns();
    e->syscall_id = ctx->id; e->syscall_ret = ctx->ret;
    e->ctrl_instance = c->ctrl_instance; e->cntlid = c->cntlid;
    e->submitted = g->submitted; e->completed = g->completed;
    e->later_mask = g->later_mask; e->wrapper_rc = g->wrapper_rc;
    e->cdw10 = g->last_cdw10; e->cdw11 = g->last_cdw11;
    e->cdw15 = g->last_cdw15; e->status = g->status; e->flags = g->flags;
    e->nsid = g->last_nsid; e->opcode = g->last_opcode;
    e->reason = reason;
    if (!reason) {
        /* Both sides synchronize through delete of the single permit. Before
         * consuming it, publish the issuer identity and pending signal intent.
         * Losing the delete means a watchdog already disarmed this run. */
        *(volatile __s32 *)&ctl->signal_rc = -EINPROGRESS;
        *(volatile __u64 *)&ctl->request_ns = e->exit_ns;
        if (bpf_map_delete_elem(&permit, &zero))
            e->signal_rc = -ECANCELED;
        else
            e->signal_rc = bpf_send_signal_thread(19); /* SIGSTOP: whole group */
        *(volatile __s32 *)&ctl->signal_rc = e->signal_rc;
        if (e->signal_rc) { e->reason = SIGNAL_FAILED; count(S_SIGNAL_FAIL); }
    }
    bpf_ringbuf_submit(e, 0);
    count(S_EVENT);
out:
    retire(owner, g);
    return 0;
}
char LICENSE[] SEC("license") = "GPL";
