# Validation — 19 November 2026

The release is a source project with a functional no-hardware demo, orchestration API and real C/libbpf/eBPF implementation. It has not been validated against Kundan's physical SSDs or patched migration hosts.

| Check | Result |
|---|---|
| Production C/libbpf daemon build | Passed, Clang 19.1.7 / libbpf 1.5.0 toolchain |
| Production eBPF object build | Passed, bpfel / mcpu=v3 |
| Shared C matching/gate tests | Passed, warnings treated as errors |
| Python API, orchestration, daemon and host tests | 46 run: 44 passed, 2 skipped |
| Real Unix QMP socket tests | 2 skipped: AF_UNIX socket creation blocked in this environment |
| Mocked QMP protocol and peer-PID checks | Passed |
| Synthetic five-case userspace gate tests | Passed; no BPF loaded or NVMe commands submitted |
| Host-action failure/deadline/interruption tests | Passed |
| Guest launcher idempotence and acknowledgement mocks | Passed |
| Daemon SIGKILL watchdog release | Passed using disposable process |
| JavaScript syntax and DOM ID references | Passed |
| Shell syntax, Python compilation, JSON parsing | Passed |
| Preserved migration v3 script | Byte-for-byte comparison passed |
| Browser visual/end-to-end UI validation | Not performed: local browser runtime unavailable and cloud browser could not reach the local preview |
| BPF verifier, CO-RE relocation and live attachment | Not tested |
| Patched QEMU/kernel command compatibility | Not tested on lab hosts |
| Real NVMe reset/deletion and two-PC migration | Not tested |
| Guest I/O continuity / data integrity | Not tested |

The final `make test` completed successfully. The complete output is in [tests/RESULTS.txt](tests/RESULTS.txt). The source package keeps executable permissions on shell helpers and excludes locally built binaries; build the daemon and hooks together on your Linux host.

Tests exercise automatic action exactly once, automatic/manual release, action failure cleanup, cancellation, control-channel EOF, hold deadlines, watchdog recovery, stale runs, token/origin protection, configured argv quoting, host input validation, destination-first preparation, PID/device drift checks, concurrent-operation guards, destructive-target acknowledgement, generic selector bounds and migration-start state guards.

The host bridge tests mock NVMe calls. A test log saying `Executing namespace-delete` describes mocked argv validation; no namespace was deleted. No live migration, reset or hardware mutation was performed in this environment.

`DONE` means checkpoint cycle completion. `migration_script_status` is a separate script outcome. `migration_result` remains `NOT VERIFIED`; neither a demo nor a zero script exit code proves data integrity.

First hardware run: retain the known-working kernel/QEMU and source/destination launchers, configure both host JSON files and controller profiles, run preflight and preparation, select a no-op checkpoint, load hooks, and then start migration. The daemon must report ARMED before migration starts. Validate the real gate before enabling the intended reset or namespace-deletion action. See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).
