# Run UVP from Windows against two Linux migration hosts

The Windows laptop needs a browser and an SSH client. Run the native controller and its shell workers on the source Linux PC or a separate Linux machine that can reach both migration PCs over SSH.

| Direction | Example port | Purpose |
|---|---:|---|
| Windows → Linux controller | 22 | SSH tunnel to the loopback UI |
| Controller → each host | 22 | Prepare QEMU, start the daemon and collect events |
| Source → destination | 4444 | QEMU migration stream |
| Source → destination | 10809 | NVMe NBD export, usually `uvp-nvme` |
| Source → destination | 10810 | Root-disk NBD export, named `root` by the supplied script |

## Install on the source and destination

Copy the same checkout to both PCs. Run the appropriate command from the project root **on that PC**:

```bash
# Source Linux PC
sudo bash scripts/install-host.sh --role source --install-deps
```

```bash
# Destination Linux PC
sudo bash scripts/install-host.sh --role destination --install-deps
```

The installer supports Debian/Ubuntu dependency installation. It installs the manifest files under `/opt/uvp-orchestrator`, builds the native helpers, daemon and BPF object, creates runtime/log directories, and supplies a role-specific `/etc/uvp/host.json` on first installation. Retain each host’s existing patched QEMU/kernel, assignments, VM images and NBD configuration.

Hardware mode uses native x86-64 Linux with BTF, pidfd support, compatible request/completion hooks and a branch exposing the selected migration wrapper. Build tools include a C compiler, make, pkg-config, distro clang with the BPF target, and libbpf, libelf and zlib development packages. Runtime tools include Bash, jq, util-linux, coreutils, OpenSSH, nvme-cli and socat.

## Point each host at its existing QEMU launcher

```bash
sudoedit /etc/uvp/host.json
```

| Host setting | Source | Destination |
|---|---|---|
| `launch_argv` | Existing source VM launcher | Existing incoming VM launcher and NBD exports |
| `qemu_executable` | Exact source QEMU binary | Exact destination QEMU binary |
| `pidfile`, `qmp_socket` | Paths used by source QEMU | Paths used by destination QEMU |
| `controller`, `cntlid` | Host admin device and target controller ID | Destination device and target controller ID |
| `migration_argv` | Cross-host migration program, invoked with the destination IP | Migration starts on the source |

Edit the example values for your lab. The launcher must return after starting QEMU so the bridge can verify the process. Point each VM's existing QEMU command at a private pidfile and Unix QMP socket. For example, the source options below must match the source configuration:

```bash
-pidfile /run/uvp-hmlm/source.pid \
-qmp unix:/run/uvp-hmlm/source.qmp,server=on,wait=off
```

The bridge checks the executable and QMP peer PID to identify the VM it will prepare or migrate. The eBPF checkpoint discovers its own target from command submission. Preparation expects the destination QMP status `inmigrate` and the source status `running`. For a destination using deferred incoming migration, run the usual incoming setup in its launcher. Host configurations, privileged scripts and their parent directories must have trusted ownership and permissions.

## Configure the cross-host migration script

The included `migration/migrate-cross-host-repeat-safe-v3.sh` takes a unicast IPv4 destination address. It uses the source QMP, the CDQ/baseline/delta flow, root-disk NBD synchronization, RAM/VFIO transfer, and final cutover from the existing setup. It reads settings from the source host JSON `environment` through the bridge.

| Setting | Use |
|---|---|
| `SOURCE_QMP` | The bridge uses the prepared source’s `qmp_socket` |
| `HMLM_CTRL`, `HMLM_SRC` | Host admin controller and source namespace device |
| `HMLM_MCID`, `HMLM_NSID` | Migration controller and namespace IDs as decimal strings |
| `MIGRATION_PORT`, `NVME_NBD_PORT`, `NVME_NBD_EXPORT`, `ROOT_NBD_PORT` | Values matching the incoming destination and exported disks |
| `QMP_EVENT_LOG` | Writable source event-log path |
| `HMLM_FULL_RAM_FINAL`, `HMLM_FINAL_TIMEOUT_MS`, `HMLM_DELTA_SETTLE_MS` | Settings for final RAM transfer, timeout and delta settling |

The script uses a source disk and destination NBD export named `root`, and the block-node names `hmlm-src`, `hmlm-dst` and `hmlm-delta-dst`. Its QMP commands and schema must match your working patched QEMU.

## Configure and start the Linux controller

On a separate Debian/Ubuntu control PC, install `build-essential jq util-linux coreutils openssh-client`. Run the following from its writable project checkout. A controller on the source can use the checkout or the binaries built by the host installer.

```bash
make controller
cp config/hardware-v2.example.json config/hardware.json
${EDITOR:-vi} config/hardware.json
./scripts/start-controller.sh --hardware --config "$PWD/config/hardware.json"
```

For a root-owned installation, write the controller config to a file owned by the operator and pass its absolute path. The controller's source and destination settings select separate SSH addresses/users, ports, identity files, known-hosts files and privileged command prefixes. Verify host keys using your lab procedure, and allow noninteractive execution of the configured daemon/bridge on each host. The example uses `sudo -n`. The installer leaves account, SSH key and sudoers provisioning to your lab.

Controller IP edits in the UI apply to its current session. Machine-specific devices, executables and SSH credentials come from the JSON configuration. Use `config/uvp.conf` separately if enabling guest fio jobs.

Hardware mode prints a random access token when no `UVP_TOKEN` is supplied. For a persistent token, set `UVP_TOKEN` to a secret of at least 24 characters in the launching shell. The startup script writes state under `${XDG_STATE_HOME:-$HOME/.local/state}/uvp-orchestrator`, or a directory you select with `UVP_STATE_DIR`. Give each controller a private writable state directory.

## Connect from Windows

Keep a PowerShell window open with the tunnel:

```powershell
ssh -N -L 8000:127.0.0.1:8000 uvp@CONTROLLER_IP
```

Open `http://127.0.0.1:8000/forms`. The browser asks for HTTP Basic credentials. Use username **uvp** and the token from the Linux terminal. The form uses standard HTML with server-side rendering. The optional JavaScript dashboard at `http://127.0.0.1:8000/interactive` accepts the same token in the page. To run a simulated controller instead, omit `--hardware` and the hardware config and use `uvp-demo` as the password.

## Example run — reset after source Suspend

1. Enter the source and destination host settings and select **Save hosts**. Check readiness, then select **Prepare hosts**. Destination preparation runs first.
2. Choose **Suspend** on the source, configure the hold and checkpoint deadlines, and choose automatic or manual release. For an initial hardware check, use the no-op profile.
3. For the reset experiment, set the correct host character device in the source reset profile’s arguments and enable that profile in the hardware configuration before starting the controller. Reprepare after a restart. Select the source reset profile.
4. Choose **Load eBPF hook and UVP daemon**. Use **Refresh status** until the daemon reports `ARMED`. **Start live migration** runs the configured migration script with the destination IP.
5. Inspect the captured issuer TGID and TID in the checkpoint events. The daemon confirms that the issuing process’s threads have stopped before running the reset. Automatic release follows a successful action. Check the migration script exit, then run your guest I/O and data-integrity check on the destination.

For Get, use the source. For Set and Resume, use the destination. For a custom NVMe command, select the trigger host, controller, opcode, queue and any required masks. The first matching synchronous submission on that host claims the checkpoint. A PF reset can affect multiple VFs. Namespace deletion permanently removes the configured lab namespace and requires the exact displayed controller and NSID as acknowledgement. [Command matching](GENERIC_HOOKS.md)

## Manual host operations and recovery

| PC | Command |
|---|---|
| Destination | `sudo /opt/uvp-orchestrator/scripts/DEST.sh` |
| Source | `sudo /opt/uvp-orchestrator/scripts/source.sh` |
| Either | `sudo /opt/uvp-orchestrator/scripts/host-preflight.sh` |
| Source | `sudo /opt/uvp-orchestrator/scripts/migrate.sh DESTINATION_IP` |

These commands use the same root-owned configuration as the UI. Choose one migration initiator for the run. Each Linux host accepts one armed hardware checkpoint at a time, including across different controllers, because the same process may issue commands to several controllers.

Disarm cancels the checkpoint and releases its owned stop. A migration already in progress follows its own lifetime. The daemon watchdog provides bounded release on failure. SIGCONT allows the issuing process to run again. Device recovery, namespace reconstruction, QMP state and the guest workload are separate concerns. Inspect both hosts before repeating a test after a reset, timeout, disconnection or failed migration.

Export the checkpoint’s JSON and retain the kernel, QEMU, migration and guest workload logs. [Validation scope](../VALIDATION.md)

## Upgrade an existing controller

Stop the existing controller and start the native one with the same `--data-dir`. On first startup the new controller can import the previous `uvp.sqlite3` database read-only. Install the `sqlite3` command on that controller for this one-time import. New installations write private JSON state and per-run event journals directly. The configuration reader recognizes earlier paths for the bundled host helpers. Install the shell host tools on both migration PCs before starting a hardware run.
