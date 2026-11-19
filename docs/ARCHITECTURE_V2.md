# UVP command-triggered orchestration

The Windows browser selects a command, an action and two Linux hosts. On Linux, a C HTTP server passes requests to Bash handlers. Workers prepare both hosts, arm the selected checkpoint and start the migration. The selected host's native daemon owns the issuing process stop, action and release.

```mermaid
flowchart TB
    Browser["Windows browser"] --> HTTP["C HTTP server"]
    HTTP --> API["Bash API and workers"]
    API -->|"SSH"| Src["Source QEMU and migration driver"]
    API -->|"SSH"| Dst["Incoming destination QEMU"]
    Src -->|"RAM, VFIO state and storage"| Dst
    API -->|"Selected host"| Daemon["C daemon"]
    Hooks["NVMe and syscall eBPF hooks"] -->|"Completion event"| Daemon
    Daemon --> Action["Configured host action"]
```

## Which component does what?

| Component | Responsibility |
|---|---|
| C HTTP server | Bind loopback, authenticate, check request origin and framing, route to forms/API/static files |
| Bash form and API handlers | Render HTML, validate selections, serialize state changes, start workers, export results |
| Bash workers and C helpers | Invoke configured local/SSH operations, stream daemon events and control messages, enforce deadlines |
| Host bridge and QMP helper | Read root-owned launcher configuration, verify live QEMU identity and QMP state, serialize migration |
| Native daemon | Attach hooks, hold a target pidfd, confirm the stop, run the selected action once, release the target |
| eBPF hooks | Correlate submission/completion with the originating thread and its syscall, request SIGSTOP and report the decision |
| Existing VM launchers | Establish VF, disks, QMP and NBD exports for the real lab topology |
| Supplied source migration script | Synchronize the root disk, perform CDQ/baseline/delta processing, transfer RAM and VFIO state, cut over |

## Preparation, arming and migration

The destination must first reach `inmigrate` with its incoming service and exports ready. The source must be `running`. The host bridge verifies the PID file and executable, checks the Unix QMP socket's peer PID, and queries QMP. The operator chooses one command and action per run. Source Suspend/Get checkpoints load the daemon on the source, and destination Set/Resume checkpoints load it on the destination.

After the daemon reports `READY`, the controller records `ARMED` and accepts the migration job. It starts on the source with the supplied destination address. The selected migration command must issue inside its audited complete-operation wrapper. The eBPF program records the issuing TGID/TID and request identity and observes command completion. At the original thread's syscall exit it can request SIGSTOP and emit a ring event. Get/Set can span multiple fragments. A later migration transition in the same syscall invalidates an earlier boundary. [Command details](GENERIC_HOOKS.md)

## Action and release

The daemon checks that the registered process's threads have reached a stopped state. At `HOLD_READY`, the worker can send the literal `action` command over the persistent daemon control channel. The program and arguments were chosen from the trusted profile when arming. Successful completion returns to held state. An operator or the automatic worker can then send `resume`, and the daemon sends SIGCONT and handles any post-release guest job.

Action failure, timeout or control-channel loss can trigger cleanup of the owned stop. A watchdog can release the process if the daemon dies. Hardware may already have accepted a reset or deletion, and kernel/hardware hangs can outlast the control process. An initial checkpoint cycle ending `DONE`, a zero migration-script exit and independently verified guest integrity are three distinct outcomes.

## Persistence and access

State changes use file locking and atomic replacement of JSON within the controller's state directory. Per-run events support export after a browser disconnect. Startup marks an unfinished run interrupted before accepting another. The controller-to-daemon connection has its own lifetime, separate from short-lived browser requests. [State transitions and daemon commands](ARCHITECTURE.md)

The no-JavaScript form at `/forms` uses HTTP Basic authentication with user `uvp` and the printed token. The interactive dashboard and automation use the authenticated JSON API. SSH host-key checking remains enabled for both hardware PCs. The trusted host configuration fixes paths, credentials and action argv. [Two-host installation](DEPLOYMENT.md)
