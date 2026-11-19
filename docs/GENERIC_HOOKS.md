# Command hooks: supported boundaries and validation

The daemon selects one command checkpoint per run. It captures a command when
`nvme_init_request()` runs in the selected process, links the request to the
issuing thread and current syscall, observes `nvme_complete_rq`, and requests
SIGSTOP at that same thread's syscall exit. The daemon confirms that every
thread in the selected process is stopped before it accepts a host action.

SIGSTOP applies to the whole process. SIGCONT releases that process; it is not
an NVMe Resume command and does not establish the guest's QMP runstate.

## Migration commands

Cases 1–4 retain the complete-operation kernel wrappers from the supplied UVP
implementation. They support the VFIO migration path, whose syscalls may be
VFIO feature ioctls or migration-data reads/writes, rather than NVMe passthrough
ioctls. The wrapper must remain present and have an `int` return value in the
actual test kernel. Configure a renamed symbol on the server if needed.

| Case | Command | Default wrapper | Host |
|---|---|---|---|
| 1 | Suspend complete | `nvmevf_cmd_suspend_device` | Source |
| 2 | Get controller state complete | `nvmevf_cmd_get_ctrl_state` | Source |
| 3 | Set controller state complete | `nvmevf_cmd_set_ctrl_state` | Destination |
| 4 | Resume complete | `nvmevf_cmd_resume_device` | Destination |

The migration decoder follows the supplied test implementation: Send opcode
0x41, Receive opcode 0x42, and the command-dword selectors in `uvp.h`. These
definitions must agree with the kernel/device revision used in your lab.
The Get/Set wrappers prevent a single header/chunk completion from being treated
as completion of the entire state transfer. A later migration transition in the
same syscall invalidates the checkpoint: stopping at syscall exit cannot create
a pause between operations that have already both happened inside that syscall.

## Custom command selector

Case 5 requires `--opcode` and `--queue admin|io`. The controller is still
selected using `--controller /dev/nvmeN`, and the issuing process using `--pid`.
Queue identity distinguishes admin opcodes from overlapping I/O opcodes.

| Option pair | Match rule | Default |
|---|---|---|
| `--nsid`, `--nsid-mask` | `(command.nsid & mask) == (value & mask)` | Mask 0, wildcard |
| `--cdw10`, `--cdw10-mask` | Same rule for command dword 10 | Mask 0, wildcard |
| `--cdw11`, `--cdw11-mask` | Same rule for command dword 11 | Mask 0, wildcard |

Decimal and `0x` hexadecimal values are accepted. Use `0xffffffff` for an exact
32-bit match. `--cntlid` is not a custom-command filter; use the appropriate
command-dword mask if the chosen command encodes a controller identifier there.

Example: observe successful Identify Controller (CNS=1) in a known, persistent
command-issuing process on `/dev/nvme0`:

```bash
sudo ./vendor/uvp-live-fio/bin/uvp-daemon \
  --pid 12345 --case 5 --controller /dev/nvme0 \
  --opcode 0x06 --queue admin --cdw10 1 --cdw10-mask 0xff \
  --bpf ./vendor/uvp-live-fio/bin/hooks.bpf.o \
  --control-stdin --hold-timeout 120 --timeout 300 -- /bin/true
```

Replace the PID with the actual command issuer. The daemon does not follow
children and must be armed before that process issues the selected command.
For a short-lived nvme-cli process, arrange a supervised startup gate outside
this example; do not guess or reuse a numeric PID. PID identity is additionally
checked using the process start time and pidfd.

Without `--phase-symbol`, custom mode admits only native x86-64 synchronous
NVMe passthrough ioctls: `NVME_IOCTL_ADMIN_CMD`, `NVME_IOCTL_ADMIN64_CMD`,
`NVME_IOCTL_IO_CMD`, `NVME_IOCTL_IO64_CMD`, and `NVME_IOCTL_IO64_CMD_VEC` when
provided by the build host's UAPI headers. The ioctl must return zero and every
tracked command must complete successfully. io_uring, 32-bit compat ioctls,
ordinary buffered/direct filesystem I/O, background worker commands, and guest
I/O on a VF assigned to VFIO are not supported by this default adapter.

An optional `--phase-symbol NAME` enables an audited synchronous, int-returning
kernel wrapper for a different path. It requires command submission and wrapper
execution in the same selected issuing thread and syscall. The operator must
verify that the wrapper covers the entire intended operation. This option does
not make asynchronous paths supported.

Multiple sequential matching commands within one supported operation can be
counted, and the pause occurs only after all have completed at syscall exit.
Overlapping outstanding matches, a missing completion, read/map tracking failure,
wrapper error, syscall error, or NVMe error reject the checkpoint. The payload
contains the first submission timestamp, last completion timestamp, counts, and
last matching command fields. It does not provide a breakpoint between commands
inside one syscall. A run is one-shot, including a rejected matching checkpoint.

## Recovery limits

Only the daemon owns the target's pidfd and stop/release sequence. On ordinary
failure it disarms, kills the launched action process group, waits up to one
second to reap the action, and releases its registered target. It warns if an
uninterruptible action worker persists. An independent watchdog also releases an
owned hold when the daemon dies or the bounded hold expires. That crash path
cannot establish that every action descendant or hardware operation has stopped;
the direct worker uses a parent-death SIGKILL, but hardware effects and kernel
hangs cannot be rolled back. These runs are failures requiring host inspection.

## Build and validation

Build the daemon and BPF object from the same checkout. Their shared map/event
ABI is version 2; do not combine this daemon with an earlier `hooks.bpf.o`.
Use a native x86-64 Linux host with matching BTF, kprobes, raw tracepoints,
ring buffers, pidfd support and permission to load BPF. The target kernel must
expose the referenced NVMe types, fields, tracepoint and wrapper symbols.

Validated in this project environment:

- Production C/libbpf daemon and `bpfel` object compile using Clang 19.1.7 and
  libbpf 1.5.0, with a toolchain extracted into scratch without root installation.
- Shared C tests cover legacy migration decoding, opcode/queue/mask matching,
  synchronous ioctl admission, completion counts and gate rejection conditions.
- Test-only and production daemon synthetic runs exercise stop/release, all five
  cases, invalid selectors, action failure/deadline, interruption and watchdog
  recovery. These runs create disposable child processes and issue no NVMe I/O.
- The daemon integration tests exercise interactive action/resume,
  disconnect, cancellation, hold deadlines and failure cleanup.

Not validated here: kernel BPF verifier acceptance/attachment, CO-RE relocation
against your patched kernel, actual controller resets or namespace deletion,
hardware command interception, two-host live migration, and post-migration data
integrity. Compile success and synthetic tests do not establish those results.

Primary implementation references:

- [Linux NVMe ioctl UAPI](https://github.com/torvalds/linux/blob/master/include/uapi/linux/nvme_ioctl.h)
- [Linux NVMe ioctl implementation](https://github.com/torvalds/linux/blob/master/drivers/nvme/host/ioctl.c)
- [Linux NVMe request initialization](https://github.com/torvalds/linux/blob/master/drivers/nvme/host/core.c)
