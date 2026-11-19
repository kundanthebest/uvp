# Deploy UVP on two Linux PCs and use it from Windows

UVP runs the web server and orchestrator on Linux. Your Windows laptop needs a browser and an SSH client; it does not load eBPF or run the NVMe commands. The orchestrator reaches the source and destination hosts over SSH. The selected host runs the native eBPF loader and UVP daemon.

This project includes the orchestration layer, native daemon/hooks, web UI, setup wrappers, and your repeat-safe v3 migration script. It uses your already-working patched kernel, QEMU, VF/namespace assignments, VM images and hardware-specific launchers. Those machine-specific inputs must be configured before hardware mode can run. Hardware migration, reset and namespace deletion were not exercised in the build environment; see the root validation report for the checks that were run.

## 1. Choose the three roles

The controller can be the source PC or another Linux machine with SSH access to both PCs. Source and destination are separate Linux hosts for this workflow.

| Machine | Runs | Connection |
|---|---|---|
| Windows laptop | Edge/Chrome/Firefox, SSH tunnel | Laptop → controller SSH |
| Linux controller | Python web API, job sequencing, event history | Controller → source and destination SSH |
| Source Linux PC | Source QEMU, source migration script, source hooks when selected | Source → destination migration/NBD ports |
| Destination Linux PC | Incoming destination QEMU, NBD exports, destination hooks when selected | Accepts source traffic |

If the source is also the controller, the logical roles still remain separate. The example controller configuration uses SSH for both hosts so that the same deployment procedure works from a separate control machine.

Typical ports in the bundled migration script are listed below. Keep the configured values consistent with your existing destination launcher and laboratory network rules.

| Direction | Port | Purpose |
|---|---:|---|
| Laptop → controller | 22 | SSH tunnel to the loopback web server |
| Controller → each Linux host | 22 | Host preparation, daemon control and job launch |
| Source → destination | 4444 | QEMU migration stream |
| Source → destination | 10809 | NVMe NBD export, normally `uvp-nvme` |
| Source → destination | 10810 | Root disk NBD export, named `root` by the bundled script |

The browser uses `http://127.0.0.1:8000` through the tunnel. Do not expose the Python HTTP listener or unprotected migration/NBD services to the Internet.

## 2. Install the project on both migration hosts

Unzip the downloaded project or clone your repository. On an Ubuntu/Debian source host:

```bash
cd uvp-orchestrator
sudo bash scripts/install-host.sh --role source --install-deps
```

On the destination host:

```bash
cd uvp-orchestrator
sudo bash scripts/install-host.sh --role destination --install-deps
```

The installer puts the project at `/opt/uvp-orchestrator`, builds the real daemon and BPF object, and creates `/etc/uvp/host.json` from the corresponding example if that file does not already exist. Omit `--install-deps` if the build/runtime packages are already installed. Review the installer before using it on a distribution other than Ubuntu/Debian.

The runtime is native x86-64 Linux. It needs the required BPF features, running kernel/module BTF, compatible NVMe request/completion hooks, and the selected migration wrapper symbols. The kernel and QEMU patches from your working live-migration setup are prerequisites, not installed by this project.

Expected real build outputs are:

```text
/opt/uvp-orchestrator/vendor/uvp-live-fio/bin/uvp-daemon
/opt/uvp-orchestrator/vendor/uvp-live-fio/bin/hooks.bpf.o
```

Do not substitute the userspace test binary from `build/` for the real daemon.

## 3. Configure each host's existing VM launcher

Edit the root-owned file on each host:

```bash
sudoedit /etc/uvp/host.json
```

Start from `config/host-source.example.json` on source and `config/host-destination.example.json` on destination. Replace every hardware-specific example with the values used by your validated setup.

The host configuration must identify:

- The source or destination role.
- The trusted, absolute argv for your existing source or destination launcher.
- The exact QEMU executable, PID file and Unix QMP socket.
- The host admin controller device and target NVMe CNTLID.
- The `environment` object passed to the launcher and migration command. If a launcher needs a particular working directory, set it inside that trusted launcher.
- On source, the migration argv and explicit environment for the bundled migration script.

Keep this configuration and the referenced privileged scripts owned by root and not writable by untrusted users. Browser form fields do not replace the executable paths in this file.

Your existing source launcher must start source QEMU with an explicit PID file and Unix QMP server, for example the following options added to its existing QEMU command:

```bash
-pidfile /run/uvp-hmlm/source.pid \
-qmp unix:/run/uvp-hmlm/source.qmp,server=on,wait=off
```

The destination launcher must similarly use its configured destination PID file and QMP socket, and start QEMU ready for incoming migration. It must also establish the NVMe and root-disk NBD exports required by your migration flow. Preserve your working VF BDFs, namespace/controller mapping, disks, machine type, migration options and QEMU patch-specific properties.

These option fragments are not complete VM launch commands. The wrapper does not invent device assignments, create a namespace, format disks or construct a replacement VM definition.

Preparation verifies the live process and QMP connection. The source must report QMP status `running`; the destination must report `inmigrate`. Merely having a PID file is insufficient. A stale PID, different executable, wrong QMP peer or wrong runstate causes preparation to fail instead of marking the host ready. Remove or recover old VMs using your normal lab procedure; do not delete a PID file merely to bypass an identity check.

If your established destination uses `-incoming defer`, it must issue the appropriate `migrate-incoming` command during preparation and reach `inmigrate`. `prelaunch` alone is not accepted as proof that the destination is listening for this migration.

## 4. Configure the source migration environment

The preserved script is:

```text
migration/migrate-cross-host-repeat-safe-v3.sh
```

It takes the destination IP as its one positional argument. It reads settings from environment variables; it does not source `UVP_CONFIG` or `uvp-hmlm.conf`. Set the actual values in the source host configuration's `environment` object. The bridge overrides `SOURCE_QMP` with its configured `qmp_socket` to keep the migration tied to the prepared VM. The current bundled script accepts a unicast IPv4 destination address; enter an IPv4 address for the destination in the UI.

| Variable | Meaning |
|---|---|
| `SOURCE_QMP` | Source QMP socket; must match the prepared source VM |
| `HMLM_CTRL` | Host NVMe admin controller |
| `HMLM_SRC` | Source host namespace block device |
| `HMLM_MCID` | Migration controller ID used by the HMLM command |
| `HMLM_NSID` | Namespace ID being migrated |
| `NVME_NBD_PORT`, `NVME_NBD_EXPORT` | Destination namespace NBD service/export |
| `ROOT_NBD_PORT` | Destination root disk NBD service; export is `root` |
| `MIGRATION_PORT` | Destination QEMU incoming migration port |
| `QMP_EVENT_LOG` | Source event-log path |
| `HMLM_FULL_RAM_FINAL` | Enables the script's full-RAM final stage when `on` |
| `HMLM_FINAL_TIMEOUT_MS` | HMLM final-stage timeout |
| `HMLM_DELTA_SETTLE_MS` | Delta visibility settling interval |

Use decimal strings for numeric fields consumed with `jq --argjson`, such as `HMLM_MCID` and `HMLM_NSID` (`"129"`, not `"0x81"`). The source QEMU root disk must have the block device name `root`, and the destination root NBD export must also be named `root`. The script creates and uses the `hmlm-src`, `hmlm-dst` and `hmlm-delta-dst` block-node names; avoid unrelated pre-existing nodes with those names.

The bundled source script includes root-disk synchronization, CDQ arming, physical-NVMe baseline copy, independent delta transfer, RAM/VFIO migration, and final cutover. It expects the patched QEMU commands and schema used by your previous setup. A successful source launcher does not establish those capabilities; retain your known-working kernel/QEMU combination and check script output on the first run.

## 5. Configure controller SSH access

On the Linux controller, copy the project to a private working directory or use `/opt/uvp-orchestrator`. Python 3.10+ and OpenSSH are needed; the web backend has no pip or npm dependency.

Use a lab account with the privileges required to launch QEMU, load BPF, and execute the enabled host actions. Configure SSH keys and verify each server's host-key fingerprint through your normal trusted channel before adding it to `known_hosts`. The orchestrator uses batch mode and strict host-key checking; it will not prompt for a password or accept an unknown key silently.

Copy and edit the controller example:

```bash
cd /opt/uvp-orchestrator
sudo cp config/hardware-v2.example.json config/hardware.json
sudoedit config/hardware.json
```

Set each host's SSH address/account/port, identity file, known-hosts file and privilege prefix. If the connected account already has sufficient privileges, the prefix is `[]`; otherwise the example uses noninteractive `sudo -n`. This project does not modify sudoers or provision an SSH key for you.

Giving an account permission to execute the daemon with arbitrary configured actions is a privileged lab capability. Treat its credentials and the controller token accordingly; it is not a restricted multi-user privilege boundary.

The controller configuration and host configuration serve different purposes:

| File | Stored on | Controls |
|---|---|---|
| `config/hardware.json` | Linux controller | SSH connections, action/job profiles, bridge and daemon paths |
| `/etc/uvp/host.json` | Each migration PC | Trusted local launcher, VM identity, controller identity and migration environment |
| `config/uvp.conf` when guest fio is used | Relevant daemon host(s) | Legacy guest SSH runner and fio settings |

Editing a host IP in the UI updates the controller's connection selection for the current session. It does not rewrite the remote VM launcher's disks, BDFs or namespace configuration. Reprepare the hosts after changing connection settings.

## 6. Start the controller and connect from Windows

On the Linux controller:

```bash
cd /opt/uvp-orchestrator
bash scripts/start-controller.sh --hardware --config config/hardware.json
```

The start script stores run history in your user state directory (`~/.local/state/uvp-orchestrator` by default), so the controller need not write inside the root-owned installation. Set `UVP_STATE_DIR` to choose another private writable directory. Keep the printed access token available. The server listens on `127.0.0.1:8000`. To use a persistent operator-managed token, set `UVP_TOKEN` to a securely generated string of at least 24 characters before launch; do not commit it to GitHub.

In Windows PowerShell, keep this tunnel terminal open:

```powershell
ssh -N -L 8000:127.0.0.1:8000 your-user@CONTROLLER_IP
```

Then open:

```text
http://127.0.0.1:8000
```

Enter the controller token in the UI. The included `scripts/windows-connect.ps1` provides the same tunnel convenience. Windows does not need Linux eBPF packages or a local NVMe device. Closing the browser does not stop the Linux run; reconnect to inspect it.

For a no-hardware UI demonstration, run the controller without `--hardware`. Demo mode uses the token `uvp-demo` and does not execute NVMe operations, signal QEMU or load BPF.

## 7. Run the first test

1. Enter the source and destination Linux server IPs and SSH account details. Save the host settings.
2. Run **Preflight**. Fix missing files, SSH access, privileges or kernel prerequisites reported in the event log. Preflight is not proof that the BPF verifier will accept the program.
3. Click **Prepare hosts**. UVP prepares destination first, then source, and obtains verified current QEMU PIDs and host controller identities.
4. Select **Suspend complete** and a source action. For the initial integration test, use no action or a configured non-destructive action.
5. Choose automatic action execution and automatic release, or select manual release to inspect the held checkpoint. Set finite checkpoint and hold timeouts.
6. Click **Load eBPF + daemon**. Wait for `ARMED`, meaning the daemon loaded and attached its requested hooks.
7. Click **Start live migration**. The source migration script begins with the destination IP supplied by the controller.
8. When the selected command completes and the eligible syscall exits, the daemon confirms the QEMU group stop, executes the action once, and releases the owned stop according to the selected mode.
9. Inspect the checkpoint result and migration-script result separately. Verify destination guest I/O and data integrity using your established workload before declaring the migration test a pass.

A controller/API connection badge is not an eBPF readiness signal. Do not start migration while the daemon is still starting or after arming fails.

## 8. Configure reset and namespace-deletion actions

Hardware action profiles are disabled until you review their exact targets and enable them in `config/hardware.json`. Actions are fixed argv profiles, not free-form shell text received from the browser. Each selected action runs once on the checkpoint daemon host.

For **NVMe controller reset**, check the configured character device carefully. A host PF reset can affect multiple VFs or namespaces. The action target is explicit in its profile; it must not be assumed to equal a guest's `/dev/nvme0`.

For **namespace deletion**, configure the exact host controller and NSID and use only the disposable namespace intended for this test. The profile and UI require an explicit target acknowledgement. Deletion can make migration fail by design and is not undone by releasing QEMU. The project does not recreate, reattach or restore the deleted namespace automatically.

For **VF FLR**, configure the exact VF BDF. The helper requires a VF and the `flr` reset method; it does not silently fall back to a PF or bus reset. A VFIO-owned VF may refuse the reset, which is a failed action.

A custom action can execute your workload or reset sequence through an operator-owned script. Return nonzero if any required step fails, and keep the script in the foreground if the checkpoint must remain held until it finishes. Processes that detach or run remotely may outlive the action worker and require manual recovery.

## 9. Select other NVMe commands

The four migration presets use the matching complete-operation wrapper on the appropriate host:

| Preset | Hook host | Logical boundary |
|---|---|---|
| Suspend complete | Source | Successful Suspend wrapper, then issuing syscall exit |
| Get controller state complete | Source | Complete Get wrapper, including all tracked chunks |
| Set controller state complete | Destination | Complete Set wrapper, including all tracked chunks |
| Controller resume complete | Destination | Successful Resume wrapper, then issuing syscall exit |

The custom-command option requires an opcode and an `admin` or `io` queue selector. NSID, CDW10 and CDW11 each have a value/mask pair; a zero mask means wildcard. Without a configured wrapper, case 5 accepts native x86-64 synchronous NVMe passthrough ioctls (`ADMIN_CMD`, `ADMIN64_CMD`, `IO_CMD`, `IO64_CMD`, `IO64_CMD_VEC`). It correlates commands issued by the exact selected TGID through request completion to that process's syscall exit. The selected process must exist before arming.

This default path does not support `io_uring`, compatibility-mode ioctls, ordinary fio block I/O, unrelated kernel workers or arbitrary guest VFIO passthrough commands. For another kernel path, a server-configured `phase-symbol` must identify an audited synchronous, integer-returning complete-operation wrapper. Sequential matching requests in one syscall must all complete successfully; overlapping matching requests are rejected. Build the daemon and BPF object from the same source version because they share an event/map ABI.

A syscall can contain more than one NVMe command. A syscall-exit stop occurs after that syscall's eligible work, not between its internal commands. The migration presets retain their later-transition rejection; for example, Set and Resume in one syscall cannot be represented honestly as a stop between Set and Resume. Use an audited adapter or kernel/QEMU boundary change if your required checkpoint is not separately observable.

SIGSTOP delivery is process-level and has scheduling latency. It does not freeze the SSD, the host, other processes or unrelated in-flight commands.

## 10. Host commands and recovery

These wrappers use the same root-owned host configuration as the UI:

| Run on | Command | Effect |
|---|---|---|
| Destination | `sudo bash /opt/uvp-orchestrator/scripts/DEST.sh` | Prepare/verify incoming destination VM |
| Source | `sudo bash /opt/uvp-orchestrator/scripts/source.sh` | Prepare/verify running source VM |
| Source | `sudo bash /opt/uvp-orchestrator/scripts/migrate.sh DESTINATION_IP` | Start the configured cross-host migration script |
| Either host | `sudo python3 /opt/uvp-orchestrator/scripts/host-preflight.py` | Inspect configured prerequisites |

For UI operation, let the controller invoke these steps in its ordered workflow. Do not start a second migration concurrently from another terminal.

**Cancel checkpoint** cancels the hook/action cycle and releases an owned stop; it does not cancel QEMU migration or roll back a reset/deletion. Action failure, timeout or daemon control-channel loss also invokes bounded cleanup. The independent daemon watchdog provides an emergency release for its owned process. It cannot repair a failed device, force an uninterruptible kernel task to stop, or undo completed storage operations.

SIGCONT releases the QEMU host process. It does not issue the NVMe Resume command, force vCPUs into `running`, or send QMP `cont`. The normal migration state machine remains responsible for those transitions.

After a failed or injected run, inspect source and destination QMP state, device state, migration logs and the guest before rearming. Preparation does not destroy old VMs or rebuild missing namespaces to make the next run appear ready. The controller's exported JSON records observations and action outcomes; retain your kernel logs, QEMU logs and workload results alongside it.

The host `migration_timeout` defaults to 1700 seconds, below the controller example's 1800-second job limit. The bridge runs the migration script in its own process group under `timeout`, forwards termination/disconnect signals to that group, and retains a host lock. It never puts an already prepared QEMU in that group. A timeout or disconnect is not rollback: inspect both VM/controller states before another migration.
