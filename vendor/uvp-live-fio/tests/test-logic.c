// SPDX-License-Identifier: GPL-2.0-only
#include <assert.h>
#include <stdio.h>
#include "uvp.h"
int main(void)
{
    struct nvme_wire c={.opcode=UVP_SEND,.cdw11=0x10001};
    struct uvp_gate g={.entered=1,.returned=1,.submitted=1,.completed=1};
    assert(uvp_command_case(&c)==TC_SUSPEND);
    c.cdw11=1; assert(uvp_command_case(&c)==0); /* Notification */
    c.opcode=0x43; assert(uvp_command_case(&c)==0);
    c.opcode=UVP_RECV; assert(uvp_command_case(&c)==TC_GET);
    c.opcode=UVP_SEND; c.cdw10=2|(3U<<16);
    assert(uvp_command_case(&c)==TC_SET);
    c.cdw10=1; assert(uvp_command_case(&c)==TC_RESUME);
    c.cdw10=99; assert(uvp_command_case(&c)==0);
    assert(uvp_gate_reason(&g,0)==OK);
    assert(uvp_gate_reason(&g,48)==OK); /* migration-data read/write return */
    assert(uvp_gate_reason(&g,-5)==BAD_SYSCALL);
    g.inside=1; g.returned=0;
    assert(uvp_gate_reason(&g,0)==BAD_WRAPPER); /* header is not full Get */
    g.inside=0; g.returned=1; g.submitted=2;
    assert(uvp_gate_reason(&g,0)==BAD_COMPLETION);
    g.completed=2; assert(uvp_gate_reason(&g,0)==OK);
    g.command_error=1; assert(uvp_gate_reason(&g,0)==BAD_COMPLETION);
    g.command_error=0; g.later_mask=1U<<TC_RESUME;
    assert(uvp_gate_reason(&g,0)==LATER_PHASE);
    g.later_mask=0; g.wrapper_rc=-1;
    assert(uvp_gate_reason(&g,0)==BAD_WRAPPER);

    /* Admin and I/O opcodes overlap. Queue identity must be part of matching. */
    struct uvp_config cfg={.testcase=TC_CUSTOM,.opcode=0x06,
        .queue=UVP_QUEUE_ADMIN};
    c=(struct nvme_wire){.opcode=0x06,.nsid=7,.cdw10=0x12345601,
        .cdw11=0x98760081};
    assert(uvp_custom_match(&cfg,&c,1));
    assert(!uvp_custom_match(&cfg,&c,0));
    cfg.opcode=0x02; assert(!uvp_custom_match(&cfg,&c,1));
    cfg.opcode=0x06; cfg.nsid=7; cfg.nsid_mask=0xffffffffU;
    assert(uvp_custom_match(&cfg,&c,1));
    cfg.nsid=8; assert(!uvp_custom_match(&cfg,&c,1));
    cfg.nsid_mask=0; /* explicit wildcard */
    cfg.cdw10=1; cfg.cdw10_mask=0xff;
    cfg.cdw11=0x81; cfg.cdw11_mask=0xffff;
    assert(uvp_custom_match(&cfg,&c,1));
    cfg.cdw10=2; assert(!uvp_custom_match(&cfg,&c,1));
    cfg.cdw10=1; cfg.cdw11=1; assert(!uvp_custom_match(&cfg,&c,1));
    cfg.cdw11=0x81; cfg.cdw10_mask=0xffffffffU;
    assert(!uvp_custom_match(&cfg,&c,1));
    cfg.cdw10=0x12345601; assert(uvp_custom_match(&cfg,&c,1));

    /* Native synchronous passthrough admission explicitly excludes async and
     * ordinary read/write. Migration wrappers retain their separate route. */
    assert(uvp_custom_ioctl(16,NVME_IOCTL_ADMIN_CMD,UVP_QUEUE_ADMIN));
    assert(uvp_custom_ioctl(16,NVME_IOCTL_ADMIN64_CMD,UVP_QUEUE_ADMIN));
    assert(!uvp_custom_ioctl(16,NVME_IOCTL_IO_CMD,UVP_QUEUE_ADMIN));
    assert(uvp_custom_ioctl(16,NVME_IOCTL_IO_CMD,UVP_QUEUE_IO));
    assert(uvp_custom_ioctl(16,NVME_IOCTL_IO64_CMD,UVP_QUEUE_IO));
#ifdef NVME_IOCTL_IO64_CMD_VEC
    assert(uvp_custom_ioctl(16,NVME_IOCTL_IO64_CMD_VEC,UVP_QUEUE_IO));
#endif
#ifdef NVME_URING_CMD_IO
    assert(!uvp_custom_ioctl(16,NVME_URING_CMD_IO,UVP_QUEUE_IO));
#endif
    assert(!uvp_custom_ioctl(426,NVME_IOCTL_ADMIN_CMD,UVP_QUEUE_ADMIN));
    assert(!uvp_custom_ioctl(0,NVME_IOCTL_IO_CMD,UVP_QUEUE_IO));
    assert(!uvp_custom_ioctl(16,NVME_IOCTL_RESET,UVP_QUEUE_ADMIN));
    /* All sequential matches must finish; concurrent/untracked ownership is
     * deliberately rejected rather than released at an ambiguous boundary. */
    g=(struct uvp_gate){.entered=1,.returned=1,.submitted=3,.completed=2};
    assert(uvp_gate_reason(&g,0)==BAD_COMPLETION);
    g.completed=3; assert(uvp_gate_reason(&g,0)==OK);
    g.tracking_error=1; assert(uvp_gate_reason(&g,0)==BAD_TRACKING);

    const __u64 owner = (123ULL << 32) | 126;
    struct uvp_control ctl = {
        .pid_tgid = owner, .start_ns = 8823, .cookie = 93, .epoch = 42
    };
    assert(uvp_same_submission(&ctl, owner, 8823, 93, 42));
    assert(!uvp_same_submission(&ctl, owner + 1, 8823, 93, 42)); /* sibling */
    assert(!uvp_same_submission(&ctl, (124ULL << 32) | 126, 8823, 93, 42));
    assert(!uvp_same_submission(&ctl, owner, 9999, 93, 42)); /* TGID reuse */
    assert(!uvp_same_submission(&ctl, owner, 8823, 94, 42)); /* next syscall */
    assert(!uvp_same_submission(&ctl, owner, 8823, 93, 43)); /* next run */
    g.start_ns = 8823; g.thread_start_ns = 8855;
    assert(uvp_same_task_lifetime(&g, 8823, 8855));
    assert(!uvp_same_task_lifetime(&g, 8823, 9128)); /* TID reused in group */
    assert(!uvp_same_task_lifetime(&g, 9128, 9150)); /* new process */
    assert(uvp_wrapper_syscall(0) && uvp_wrapper_syscall(16)); /* read/ioctl */
    assert(uvp_wrapper_syscall(328)); /* pwritev2 */
    assert(!uvp_wrapper_syscall(426)); /* io_uring_enter */
    assert(!uvp_wrapper_syscall(-1));
    puts("PASS: selectors, issuer identity, syscall admission and gate decisions (C logic)");
}
