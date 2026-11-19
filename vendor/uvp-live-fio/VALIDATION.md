# Validation record — 2026-10-16

## Executed successfully

- Native daemon/process code compiled with GCC, `-Wall -Wextra -Wshadow
  -Wformat=2 -Werror`, and linked against installed libbpf 1.5.0.
- Shared command decoder/gate-decision tests: four commands, notification and
  wrong-opcode rejection, successful positive syscall returns, failed syscall,
  header-only/incomplete-wrapper rejection, partial completion, command error,
  coalesced later phase and wrapper failure.
- All four synthetic cases: SIGSTOP -> stopped-task observation -> queue worker
  -> SIGCONT -> worker execution.
- Nonzero action exit rejected; action timeout rejected; interruption during a
  held checkpoint cannot report success.
- Independent watchdog released the synthetic target after SIGKILL of the daemon.
- Guest-launcher mocks: duplicate/lost-ack retries produced exactly one fake fio;
  completed run was not relaunched; failed fake fio preserved its nonzero status.
- Real host start-fio action, driven by the daemon, with mocked SSH acknowledgements.
  Missing guest preparation is rejected.
- Bash syntax checks on every script.
- UBSan-instrumented native daemon synthetic case 4 completed without a diagnostic.
- BPF frontend compile, optimization and ELF code generation completed. The ELF
  contains .BTF/.BTF.ext and all six expected programs. Installed libbpf parsed
  this ELF and found all six programs, without loading them into the kernel.

Actual summary: `tests/RESULTS.txt`.

## Build-environment qualification

This environment has GCC, Swift clang 17's BPF frontend, the LLVM 19 shared
library and libbpf.so.1.5.0, but lacks distro libbpf development headers, a normal
clang BPF driver, running-kernel BTF and access to the target hardware.
Network package installation was unavailable.

For local validation ONLY, minimal API-declaration headers were supplied outside
this project. Native code linked to the real installed libbpf. BPF source was
compiled to LLVM IR by clang, optimized/code-generated with LLVM 19's BPF backend,
and then parsed by libbpf. This is a compile/code-generation check, NOT a verifier
or attach test. Those local build aids are not in the zip and are not needed by
users. The normal Makefile uses distro clang and official installed libbpf headers.

No prebuilt binaries are distributed. Rebuild on your target with the normal
Makefile and development packages, then run the included tests.

## Not executed / not claimed

- Full normal Makefile build against your distro's official development headers.
- Kernel verifier acceptance, actual CO-RE relocation to your kernel/NVMe module,
  kprobe/kretprobe attachment, or hardware NVMe command-completion tracing.
- QEMU source/destination migration, any of the four hardware checkpoint tests,
  group-stop behavior under real QEMU concurrency, or precise inter-command timing.
- Real SSH connections, real guest fio, migrated tmpfs/identity continuity,
  NVMe correctness, CRC data integrity or storage recovery.
- Compatibility of the historical wrapper symbols with your latest kernel.
- Arbitrary external stop/resume owners, kernel hangs or host failures.

The tests do not convert synthetic events into a claim that BPF ran. A daemon
ACTION_ACKNOWLEDGED message is not a migration or data-integrity PASS.

## First hardware run checklist

1. Use isolated VMs and a disposable mounted guest test filesystem.
2. Build and run make test on both relevant hosts. Verify BTF and exact symbols.
3. Verify SSH/authentication and sudo -n. Prepare the source guest before migration.
4. Set actual host PIDs, PF controller instance, target CNTLID, unique run ID and
   source/destination SSH routes; copy prepared.status as necessary cross-host.
5. Arm case 1, confirm READY, then launch your known-working migration.
6. Preserve EVENT, command counts/status, STOP_CONFIRMED, SIGCONT and guest logs.
7. Confirm the recorded actual guest start time. Do not call a post-resume launch
   a source fio execution inside the suspended interval.
8. For continuity, use migrate-with-fio.sh and verify-continuity.sh, then inspect
   the final fio exit/JSON and your independent migration/data validation.
9. Cases 2/3/4 each require a new run. A coalesced-boundary rejection is NOT a pass.
