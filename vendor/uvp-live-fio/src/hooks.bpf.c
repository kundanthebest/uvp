// SPDX-License-Identifier: GPL-2.0-only
/* Author: Kundan Kumar <kundan.kumar@samsung.com>
 * Three semantic hooks plus syscall guard and a logical-operation wrapper.
 * The wrapper pair prevents Get's header read from meaning "full state done".
 * Change the wrapper SYMBOL in config, not this code, for a renamed driver.
 */
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include "uvp.h"
#if !defined(__TARGET_ARCH_x86)
#error "Port the register adapter before building for a non-x86-64 host"
#endif

/* CO-RE flavor types: offsets/sizes are relocated using the running BTF. */
struct pt_regs___uvp { unsigned long di, si, ax; }
    __attribute__((preserve_access_index));
struct task_struct___uvp {
    struct task_struct___uvp *group_leader;
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
static __always_inline struct uvp_config *my_config(void)
{
    __u32 zero = 0;
    struct uvp_config *c = bpf_map_lookup_elem(&config, &zero);
    if (!c || !c->enabled || (bpf_get_current_pid_tgid() >> 32) != c->tgid)
        return 0;
    /* Full process identity, not just a reusable numeric TGID. */
    struct task_struct___uvp *task = (void *)bpf_get_current_task(), *leader = 0;
    __u64 start_ns = 0, ticks;
    if (bpf_core_read(&leader, sizeof(leader), &task->group_leader) || !leader ||
        bpf_core_read(&start_ns, sizeof(start_ns), &leader->start_boottime))
        return 0;
    ticks = (start_ns / 1000000000ULL) * c->clock_ticks +
            (start_ns % 1000000000ULL) * c->clock_ticks / 1000000000ULL;
    if (ticks != c->start_ticks) return 0;
    return c;
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

/* Guard: unlike the CLI version, do NOT restrict this to NVME_ADMIN ioctls.
 * VFIO migration uses VFIO_DEVICE_FEATURE and migration-data read/write FDs.
 * This v1 still requires the phase to run synchronously in the QEMU TID.
 */
SEC("tracepoint/raw_syscalls/sys_enter")
int on_enter(struct enter_ctx *ctx)
{
    struct uvp_config *c = my_config();
    struct uvp_gate g = {}, *old;
    __u64 owner = bpf_get_current_pid_tgid();
    __u32 zero = 0;
    struct uvp_control *ctl;
    if (!c) return 0;
    old = bpf_map_lookup_elem(&gates, &owner);
    if (old) retire(owner, old);
    ctl = bpf_map_lookup_elem(&control, &zero);
    if (!ctl || ctl->fired) return 0;
    if (c->testcase == TC_CUSTOM && !c->use_wrapper) {
        if (!uvp_custom_ioctl(ctx->id, ctx->args[1], c->queue)) return 0;
        /* With no logical wrapper, the synchronous passthrough ioctl is the
         * operation boundary. A process-wide arbitrary syscall is not enough. */
        g.entered = g.inside = 1;
    }
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
    struct uvp_gate *g;
    (void)ctx;
    if (!my_config()) return 0;
    g = bpf_map_lookup_elem(&gates, &owner);
    if (!g) return 0;
    if (g->entered) { g->tracking_error = 1; return 0; }
    g->entered = g->inside = 1;
    count(S_WRAPPER);
    return 0;
}
SEC("kretprobe")
int phase_return(struct pt_regs___uvp *ctx)
{
    __u64 owner = bpf_get_current_pid_tgid(), ret = 0;
    struct uvp_gate *g;
    if (!my_config()) return 0;
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
    struct uvp_config *c = my_config();
    struct uvp_gate *g;
    struct uvp_owner ro;
    struct nvme_wire cmd;
    struct nvme_request___uvp *nr;
    struct nvme_ctrl___uvp *ctrl = 0;
    struct request_queue___uvp *q = 0, *aq = 0;
    __u64 owner = bpf_get_current_pid_tgid(), rq = 0, cp = 0;
    int instance = -1, kind;
    if (!c) return 0;
    g = bpf_map_lookup_elem(&gates, &owner);
    if (!g) return 0;
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
    if (g->request) { g->tracking_error = 1; return 0; }
    ro.pid_tgid = owner; ro.cookie = g->cookie;
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
    if (!g || g->cookie != saved.cookie) goto out;
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
    struct uvp_config *c = my_config();
    struct uvp_gate *g;
    struct uvp_control *ctl;
    struct uvp_event *e;
    __u64 owner = bpf_get_current_pid_tgid();
    __u32 zero = 0, reason;
    if (!c) return 0;
    g = bpf_map_lookup_elem(&gates, &owner);
    if (!g) return 0;
    /* An unrelated invocation of the wrapper must not trigger this device. */
    if (!g->entered || !g->submitted) goto out;
    if (c->testcase == TC_CUSTOM && !c->use_wrapper) {
        g->inside = 0; g->returned = 1;
    }
    reason = uvp_gate_reason(g, ctx->ret);
    if (c->testcase == TC_CUSTOM && !c->use_wrapper && ctx->ret != 0)
        reason = BAD_SYSCALL;
    if (g->syscall_id != ctx->id) reason = BAD_TRACKING;
    ctl = bpf_map_lookup_elem(&control, &zero);
    if (!ctl || __sync_val_compare_and_swap(&ctl->fired, 0, 1)) goto out;
    e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) { count(S_RING_FAIL); goto out; }
    __builtin_memset(e, 0, sizeof(*e));
    e->version = UVP_VERSION; e->testcase = c->testcase; e->epoch = c->epoch;
    e->tgid = owner >> 32; e->tid = (__u32)owner; e->cookie = g->cookie;
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
        ctl->request_ns = e->exit_ns; /* watchdog can see intent before event */
        e->signal_rc = bpf_send_signal_thread(19); /* SIGSTOP: whole group */
        ctl->signal_rc = e->signal_rc;
        if (e->signal_rc) { e->reason = SIGNAL_FAILED; count(S_SIGNAL_FAIL); }
    }
    bpf_ringbuf_submit(e, 0);
    count(S_EVENT);
out:
    retire(owner, g);
    return 0;
}
char LICENSE[] SEC("license") = "GPL";
