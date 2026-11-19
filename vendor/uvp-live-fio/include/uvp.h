/* SPDX-License-Identifier: GPL-2.0-only
 * Author: Kundan Kumar <kundan.kumar@samsung.com>
 */
#ifndef UVP_H
#define UVP_H
#include <linux/types.h>
#include <linux/ioctl.h>
#include <linux/nvme_ioctl.h>

#define UVP_VERSION 2
#define UVP_CANCELLED 1U
#define UVP_SEND 0x41
#define UVP_RECV 0x42

enum uvp_case { TC_SUSPEND = 1, TC_GET = 2, TC_SET = 3, TC_RESUME = 4,
                TC_CUSTOM = 5 };
enum uvp_queue { UVP_QUEUE_ADMIN = 0, UVP_QUEUE_IO = 1 };
enum uvp_reason {
    OK = 0, BAD_SYSCALL, BAD_WRAPPER, BAD_COMPLETION, LATER_PHASE,
    BAD_TRACKING, SIGNAL_FAILED
};
enum uvp_stat {
    S_SYSCALL, S_WRAPPER, S_SUBMIT, S_COMPLETE, S_EVENT, S_READ_FAIL,
    S_MAP_FAIL, S_RING_FAIL, S_SIGNAL_FAIL, S_MAX
};

/* Native x86-64 NVMe command wire layout, not a guessed kernel struct. */
struct nvme_wire {
    __u8 opcode, flags;
    __u16 cid;
    __u32 nsid;
    __u8 reserved[32];
    __u32 cdw10, cdw11, cdw12, cdw13, cdw14, cdw15;
};
_Static_assert(sizeof(struct nvme_wire) == 64, "NVMe command size");

struct uvp_config {
    __u32 tgid, ctrl_instance, cntlid, testcase;
    __u64 epoch, start_ticks;
    __u32 enabled, debug, clock_ticks, pad;
    __u32 opcode, queue, use_wrapper, nsid;
    __u32 nsid_mask, cdw10, cdw10_mask, cdw11, cdw11_mask;
};
struct uvp_gate {
    __u64 cookie, request, submit_ns, complete_ns, wrapper_ns;
    __s64 syscall_id;
    __s32 wrapper_rc;
    __u32 entered, inside, returned, submitted, completed;
    __u32 tracking_error, command_error, later_mask;
    __u32 last_cdw10, last_cdw11, last_cdw15;
    __u32 last_nsid, last_opcode;
    __u16 status;
    __u8 flags, pad;
};
struct uvp_owner { __u64 pid_tgid, cookie; };
struct uvp_control {
    __u32 fired;              /* 0=armed, 1=claimed (may be about to signal) */
    __s32 signal_rc;
    __u64 request_ns;
};
struct uvp_event {
    __u32 version, testcase, tgid, tid;
    __u64 epoch, cookie, submit_ns, complete_ns, wrapper_ns, exit_ns;
    __s64 syscall_id, syscall_ret;
    __u32 ctrl_instance, cntlid, submitted, completed, later_mask, reason;
    __s32 wrapper_rc, signal_rc;
    __u32 cdw10, cdw11, cdw15;
    __u32 nsid, opcode;
    __u16 status;
    __u8 flags, pad;
};

/* Shared by the BPF implementation and ordinary C unit tests. */
static __inline int uvp_custom_match(const struct uvp_config *cfg,
                                    const struct nvme_wire *cmd,
                                    int is_admin)
{
    return cmd->opcode == cfg->opcode &&
        (is_admin ? UVP_QUEUE_ADMIN : UVP_QUEUE_IO) == cfg->queue &&
        (cmd->nsid & cfg->nsid_mask) == (cfg->nsid & cfg->nsid_mask) &&
        (cmd->cdw10 & cfg->cdw10_mask) == (cfg->cdw10 & cfg->cdw10_mask) &&
        (cmd->cdw11 & cfg->cdw11_mask) == (cfg->cdw11 & cfg->cdw11_mask);
}
/* Native x86-64 ioctl ABI. No compat ioctl or io_uring admission. The caller
 * supplies the command request number from sys_enter args[1]. These NVMe
 * passthrough interfaces wait for command completion before returning. */
static __inline int uvp_custom_ioctl(__s64 syscall_id, __u64 request,
                                    __u32 queue)
{
    if (syscall_id != 16) return 0; /* __NR_ioctl, x86-64 */
    if (queue == UVP_QUEUE_ADMIN)
        return request == NVME_IOCTL_ADMIN_CMD ||
               request == NVME_IOCTL_ADMIN64_CMD;
    return request == NVME_IOCTL_IO_CMD || request == NVME_IOCTL_IO64_CMD
#ifdef NVME_IOCTL_IO64_CMD_VEC
           || request == NVME_IOCTL_IO64_CMD_VEC
#endif
           ;
}
static __inline int uvp_command_case(const struct nvme_wire *c)
{
    unsigned int sel = c->cdw10 & 0xff;
    if (c->opcode == UVP_RECV && sel == 0)
        return TC_GET;
    if (c->opcode != UVP_SEND)
        return 0;
    if (sel == 0 && ((c->cdw11 >> 16) & 0xff) == 1)
        return TC_SUSPEND; /* Not STYPE=0, Suspend Notification. */
    if (sel == 1) return TC_RESUME;
    if (sel == 2) return TC_SET;
    return 0;
}
static __inline unsigned int uvp_gate_reason(const struct uvp_gate *g,
                                            __s64 syscall_ret)
{
    if (syscall_ret < 0) return BAD_SYSCALL;
    if (!g->entered || !g->returned || g->inside || g->wrapper_rc)
        return BAD_WRAPPER;
    if (g->tracking_error) return BAD_TRACKING;
    if (!g->submitted || g->submitted != g->completed || g->request ||
        g->command_error) return BAD_COMPLETION;
    if (g->later_mask) return LATER_PHASE;
    return OK;
}
#endif
