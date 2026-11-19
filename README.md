# UVP — NVMe fault orchestration

A web UI, Python orchestrator, C/libbpf daemon, eBPF hooks and two-host migration adapters for Kundan's UVP framework. Operate it from **Edge or Chrome on a Windows laptop**; the controller, hooks and migration run on Linux.

**Implementation status:** the project is runnable in demo mode. Automated API, C userspace and process-control tests exercise the control path. The production daemon and BPF object compile successfully. Loading on your patched kernel/QEMU, actual NVMe faults and two-PC migration require validation on your lab hosts. No hardware validation is implied by a successful demo. See [VALIDATION.md](VALIDATION.md).

## Operator workflow

1. Enter the source and destination Linux IPs, SSH user and controller/CNTLID.
2. **Prepare hosts** starts or validates the destination, then source. It verifies each QEMU PID and QMP runstate.
3. Select the completed NVMe command and an action, such as controller reset or namespace deletion. Optional manual hold is available.
4. **Load eBPF + daemon** attaches the selected hook on the relevant host. Wait for **ARMED**.
5. **Start live migration** runs the migration driver on the source with the destination IP.
6. The completed command reaches its issuing thread's syscall exit. eBPF requests SIGSTOP; the local daemon confirms the process stop. The orchestrator requests the selected action, then releases the process after action success when automatic resume is enabled.
7. Export the event record. Checkpoint completion, migration-script completion and data-integrity verification are separate outcomes.

The two main buttons do not replace first-time SSH, QEMU, device and launcher configuration.

## Open the UI on Windows

Double-click [demo/uvp-demo.html](demo/uvp-demo.html) to use the offline simulator in Edge or Chrome. Select **Prepare hosts**, choose **Suspend** and **NVMe controller reset**, then click **Load eBPF + UVP daemon** and **Start live migration**. The simulator keeps its events in the current tab and can export them as JSON. For a hardware run, use the Linux controller as described below.

If you change the web UI, regenerate the offline file with `python3 demo/build.py` and check it with `node demo/check.cjs`.

## Try it without hardware

On a Linux machine with Python 3.10 or later:

```bash
unzip uvp-orchestrator.zip
cd uvp-orchestrator
python3 -m uvp_server.server
```

Open **http://127.0.0.1:8000**. Demo mode connects with `uvp-demo`. All IPs, PIDs, migration events and actions in this mode are simulated. No root, pip or npm is needed. The supplied example IPs are documentation addresses; replace them for hardware operation.

## Use real Linux hosts from Windows

See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for installation, SSH setup, exact source/destination configuration and recovery.

The hardware controller runs on the source host or another Linux control host. It reaches **both** PCs over SSH, including the source if they share a machine. Install this project on both migration PCs under `/opt/uvp-orchestrator`. The host installation script builds the real daemon and BPF object; keep these at the same version.

Configure:

- `config/hardware-v2.example.json` → a local controller configuration, with your SSH key and enabled action profiles.
- `config/host-source.example.json` → `/etc/uvp/host.json` on the source.
- `config/host-destination.example.json` → `/etc/uvp/host.json` on the destination.

The host configurations point to your **working, patched QEMU launch scripts**, with QMP sockets and pidfiles. They deliberately do not guess your PCI BDFs, backing images, VF configuration or storage layout. The latest supplied `migrate-cross-host-repeat-safe-v3.sh` is included unchanged under `migration/`; its QEMU/kernel patches remain prerequisites.

Start the hardware controller as described in the deployment guide. In Windows PowerShell, open a tunnel:

```powershell
ssh -N -L 8000:127.0.0.1:8000 uvp@CONTROLLER_IP
```

Open **http://localhost:8000** and enter the access token printed by the controller. Windows needs a browser and OpenSSH client; eBPF does not run on Windows. The dashboard binds to loopback and uses token authentication, strict SSH host-key verification, and fixed configured command profiles.

## Which PC runs which script?

| Operation | PC | Entry point |
|---|---|---|
| Web UI/API | Linux controller; browser on Windows | `python3 -m uvp_server.server` |
| Prepare incoming VM and exports | Destination | `scripts/destination.sh` / `scripts/DEST.sh` |
| Prepare running VM | Source | `scripts/source.sh` |
| Read-only prerequisite checks | Each Linux PC | `scripts/host-preflight.py` |
| Load hooks and daemon | Selected command's host | `vendor/uvp-live-fio/bin/uvp-daemon` |
| Start baseline/CDQ/RAM migration | Source | `scripts/migrate.sh DESTINATION_IP` |
| Fault action after confirmed stop | Same host as hook | Enabled `host-action.py` or trusted custom profile |

The UI invokes the same host bridge used by these wrappers. Cross-host action dispatch is not automatic: a source checkpoint uses a source action, and a destination checkpoint uses a destination action.

## Command selection

| UI command | Trigger host | Completion boundary |
|---|---|---|
| Suspend | Source | `nvmevf_cmd_suspend_device` returned and selected commands completed |
| Get Controller State | Source | Complete `nvmevf_cmd_get_ctrl_state` wrapper, including its chunks |
| Set Controller State | Destination | Complete `nvmevf_cmd_set_ctrl_state` wrapper |
| Resume | Destination | `nvmevf_cmd_resume_device` returned |
| Custom NVMe command | Source or destination | Matching opcode/queue/NSID/CDW filters on a supported synchronous syscall |

The migration presets retain your existing wire decoding (SEND `0x41`, RECV `0x42`) and wrapper names. Confirm they match your kernel branch. Generic matching accepts opcode, admin/I/O queue, NSID, CDW10 and CDW11 with masks; a zero mask ignores that field. Without an explicitly configured audited wrapper it accepts native x86-64 synchronous NVMe passthrough ioctls only. CNTLID is a migration preset filter; generic commands use CDW11/masks when that is their actual encoding.

One selected checkpoint and one preselected action are supported per run. This cannot pause halfway through one syscall: if a later migration transition has already occurred in the same syscall, the migration gate rejects the checkpoint. `io_uring`, asynchronous workqueues, compat ioctls and guest VF passthrough I/O need dedicated adapters. A generic syscall containing several sequential matches pauses after all those matches complete.

## Action and failure semantics

Controller reset and namespace deletion execute on explicitly configured devices. Destructive namespace deletion is disabled in hardware examples until configured, and requires typing the exact controller:NSID at arming. This is for disposable lab namespaces.

Automatic mode sends one action request when the local daemon reports `HOLD_READY`, and one resume request only after action success. Manual mode lets you run the selected action and release separately. Guest workloads that require a running QEMU must run before migration or after release, not while every QEMU thread is SIGSTOPped.

A bounded watchdog releases the daemon-owned process on timeout, controller disconnect or daemon failure. **Cleanup release is not a successful test and is not rollback.** An action failure fails the checkpoint; it may still have changed the device. Disarming releases the checkpoint but does not cancel an already started migration. QEMU process SIGCONT is not NVMe Resume, QMP `cont`, or proof the guest is running. Review actual VM/device state before repeating a failed or completed run.

Host IP edits apply to the current controller session; edit the JSON config to retain defaults across restarts. Run records and events persist under `var/` for direct module launch, or the user state directory when using `start-controller.sh`. Restarted active records become `INTERRUPTED`; they are never silently reattached to a PID.

## Develop and publish

```bash
make test
make build CLANG=/usr/bin/clang  # requires distro clang, libbpf and BPF headers
```

[docs/API.md](docs/API.md) documents the API. [docs/ARCHITECTURE_V2.md](docs/ARCHITECTURE_V2.md) explains the host flow. Older configuration/architecture documents are retained as references; prefer the v2 deployment guide and configuration for this project.

To create a **private** repository from the finished source on a machine with authenticated GitHub CLI:

```bash
bash scripts/publish-github.sh OWNER/uvp-orchestrator
```

Publishing needs your GitHub account connection. This package contains no repository URL and does not claim to have been uploaded. It excludes SSH keys, access tokens, runtime records and machine-specific configurations.

Author: Kundan Kumar <kundan.kumar@samsung.com>  
License: GPL-2.0-only. Existing UVP code and attribution are preserved.
