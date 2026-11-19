# UVP — NVMe migration fault testing

UVP pauses the process that submitted a selected NVMe command so you can run a controller reset, namespace deletion, or another configured action at that point in live migration. Select the command and action from a Windows browser. The eBPF submission hook discovers the issuer on the selected Linux PC.

The Linux HTTP server, eBPF hooks, daemon and host helpers are C programs. Bash scripts handle orchestration, SSH, migration, and fault actions. The primary form at `/forms` works with JavaScript disabled. An optional interactive dashboard and standalone offline simulator use JavaScript in the browser.

## Try the controller on Linux

From the cloned repository, install the basic tools and start a simulated lab. On Ubuntu or Debian:

```bash
sudo apt-get install build-essential jq util-linux coreutils openssh-client
make controller
./scripts/start-controller.sh
```

Open `http://127.0.0.1:8000/forms`. Enter username **uvp** and demo password **uvp-demo** when prompted. The demo supplies example source and destination IPs. Select **Prepare hosts**, use **Refresh status** until the hosts are ready, then select **Suspend** and a source controller reset, then load the hooks and start migration. The demo simulates the stop, action, and release. Scroll to the events to inspect their order.

For an offline Windows preview, extract the project ZIP and double-click [demo/uvp-demo.html](demo/uvp-demo.html). It runs entirely in the current browser tab.

## Run a hardware test from Windows

Use a Linux controller with SSH access to both migration hosts. It can run on the source PC. Install UVP on each host and point its role configuration at the **working QEMU launcher, pidfile, QMP socket and NVMe device** for that machine. The example launchers reference your lab installation. The existing patched kernel/QEMU, disk images, and VF/namespace assignments are prerequisites. [Two-host deployment and recovery](docs/DEPLOYMENT.md)

| Where | Entry point | Purpose |
|---|---|---|
| Destination | `scripts/DEST.sh` | Launch or verify the incoming QEMU and its exports |
| Source | `scripts/source.sh` | Launch or verify the running QEMU |
| Each host | `scripts/host-preflight.sh` | Check local prerequisites |
| Linux controller | `scripts/start-controller.sh --hardware --config /absolute/path/hardware.json` | Serve the UI and orchestrate both hosts |
| Source | `scripts/migrate.sh DESTINATION_IP` | Run the configured cross-host migration |
| Selected trigger host | `vendor/uvp-live-fio/bin/uvp-daemon`, `scripts/host-action.sh` | Arm the eBPF gate and execute the selected action |

The UI invokes the host operations. On Windows, keep this PowerShell command running, replacing the account and controller address:

```powershell
ssh -N -L 8000:127.0.0.1:8000 uvp@CONTROLLER_IP
```

1. Open `http://127.0.0.1:8000/forms`. Sign in as **uvp** with the token printed by the Linux controller.
2. Enter the source and destination IPs and SSH users. Select **Save hosts**, then **Prepare hosts**. The destination must reach `inmigrate` and the source must be `running`.
3. Select the command, its matching host action, and automatic or manual release. Reset and namespace deletion require a lab-specific enabled profile. Deletion requires typing the configured controller and NSID.
4. Select **Load eBPF hook and UVP daemon** and use **Refresh status** until the run is **ARMED**. Select **Start live migration** to start the driver on the source.
5. Inspect the checkpoint events and the migration script result. Verify guest I/O and data integrity on the destination before declaring the hardware test successful.

## Choose the command boundary

| Command | Trigger host | Boundary used at the issuing syscall exit |
|---|---|---|
| Suspend | Source | `nvmevf_cmd_suspend_device` |
| Get controller state | Source | Entire `nvmevf_cmd_get_ctrl_state` operation, including its chunks |
| Set controller state | Destination | Entire `nvmevf_cmd_set_ctrl_state` operation |
| Resume | Destination | `nvmevf_cmd_resume_device` |
| Custom NVMe command | Selected host | Synchronous command matched by opcode, queue and optional NSID/CDW masks |

Each run arms one checkpoint. The first matching submission records the process ID (TGID) and the submitting thread ID (TID). Completion can run on another CPU. Once the request completes successfully and the submitting thread exits the enclosing syscall, eBPF requests SIGSTOP and reports both IDs. The daemon confirms that the issuer’s threads have stopped before executing the host action. Automatic release sends SIGCONT after action success. A later migration transition inside the same syscall invalidates the earlier checkpoint. The generic adapter covers native x86-64 synchronous NVMe passthrough. [Hook semantics and supported commands](docs/GENERIC_HOOKS.md)

## Build and verify

```bash
make controller                   # C controller and its helpers
make build CLANG=/usr/bin/clang   # hardware build including libbpf daemon and BPF object
make test                        # shell and C tests
```

To regenerate the optional offline page after editing the dashboard, run `bash demo/build.sh`. To run the offline JavaScript checks, use `node demo/check.cjs`.

[Deployment](docs/DEPLOYMENT.md) · [Architecture](docs/ARCHITECTURE_V2.md) · [HTTP API](docs/API.md) · [Validation scope](VALIDATION.md) · [GitHub Actions](https://github.com/kundanthebest/uvp/actions/workflows/tests.yml)

Author: Kundan Kumar <kundan.kumar@samsung.com>  
License: GPL-2.0-only.
