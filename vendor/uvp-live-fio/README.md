# UVP live-migration checkpoint → guest fio

A small C/libbpf + Bash project. Select one testcase per live-migration run.
No Python dependency, kernel patch, QEMU patch, custom QMP command, reset,
format, namespace deletion, or erase is performed by this bundle.

## First: what the test can actually do

**A SIGSTOPed QEMU cannot execute guest SSH or start a guest fio process.**
During ordinary stop-and-copy, the guest vCPUs may already be migration-paused
before the NVMe Suspend command. Sending SIGCONT resumes the QEMU host process;
it does not override the migration runstate or issue NVMe Resume.

The event-triggered mode therefore implements this honest sequence:

```
Selected NVMe operation succeeds
    -> same issuing QEMU TID reaches the enclosing syscall exit
    -> BPF requests SIGSTOP and emits the event
    -> daemon observes a stopped process
    -> daemon QUEUES an action worker (it cannot execute yet)
    -> daemon sends SIGCONT to QEMU
    -> worker starts the SSH action, waiting for the guest to become runnable
    -> fio starts on the configured endpoint, normally the migrated destination
```

This mode tests the checkpoint/gate/guest-launch integration. It does **not**
prove that fio ran between Suspend and Get State, or before destination Resume.
It does **not** start fio on a paused source VM. There is no hidden `QMP cont`,
NVMe Resume, or write to guest RAM/disk to force the guest to run in that interval.

For the separate requirement **"fio starts on the source when migration starts,
and the same fio continues on destination"**, use the included pre-start wrapper.
It starts fio immediately before your existing migration command, saves its
identity, and later checks that the same process is making I/O progress on the
destination. The checkpoint daemon's action is idempotent and does not restart it.

## Four independent cases

| Case | Trigger host/process | Successful logical operation | Default wrapper symbol |
|---|---|---|---|
| 1 | Source QEMU | Suspend, not Suspend Notification | `nvmevf_cmd_suspend_device` |
| 2 | Source QEMU | Complete Get Controller State | `nvmevf_cmd_get_ctrl_state` |
| 3 | Destination QEMU | Complete Set Controller State | `nvmevf_cmd_set_ctrl_state` |
| 4 | Destination QEMU | Resume destination controller | `nvmevf_cmd_resume_device` |

These names come from the supplied VFIO-NVMe RFC lineage, not an assertion that
all symbols exist in every kernel. Verify them in your current patched kernel.
The four names are editable in `config/uvp.conf.example` and via `--phase-symbol`.
An override must be an **int-returning synchronous complete-operation wrapper**
with zero meaning success, not a partial-transfer helper or pointer-returning API.

**Get/Set protection:** request completion alone is not enough. The program waits
for the selected wrapper to return successfully and for all its tracked matching
commands to complete successfully. This prevents Get's first header read from
being mistaken for the complete state. The wrapper's semantics must be audited
on your build. This v1 does not reimplement the full protocol transfer parser.

**Coalesced transition protection:** if a later migration command for the same
target is seen by the same TID in the same syscall (for example Set followed by
Resume), the event has `later_mask != 0` and the daemon rejects the checkpoint.
It does not pretend that a syscall-exit stop happened between these commands.
Such a case needs another audited boundary/adapter; it may be unsupported on your
current build without that work. Other threads and signal-delivery latency mean
this remains a process-level gate, not an instruction-exact global protocol gate.

## Files and where to make changes

```
include/uvp.h                Event/map ABI, command decoder, gate decision
src/hooks.bpf.c              Request, completion, phase and syscall hooks
src/daemon.c                 Load/attach, stop, queue action, SIGCONT, deadlines
src/process.c               pidfd/process identity and stopped-task checks
config/uvp.conf.example      Controller/CNTLID, symbols, SSH and fio settings
scripts/start-fio.sh         DEFAULT ACTION: edit here for next userspace action
scripts/run-case.sh          Case number -> source/destination configuration
scripts/prepare-guest.sh     Stage the guest launcher before migration
scripts/migrate-with-fio.sh  Optional source-prestart + your migrate.sh
scripts/prestart-fio.sh      Optional source launch and identity baseline
scripts/verify-continuity.sh Same-process and I/O-accounting checks on destination
guest/guest-fio.sh           Actual guest fio command and durable run status
scripts/collect-results.sh  Fetch guest fio JSON/logs/exit status
tests/                      Native and mocked tests; no hardware operations
VALIDATION.md               What was tested, and what was not
```

The requested three semantic hooks remain:

1. `nvme_init_request` filters the command, controller and CNTLID. The first
   matching submission records its current TGID and TID with the request.
2. `nvme_complete_rq` **raw tracepoint**: correlate the exact request and record
   status/cancellation. Never identify the owner from completion-context PID.
3. `raw_syscalls:sys_exit`: original issuing TID, successful operation and syscall,
   one-shot ring event, `bpf_send_signal_thread(SIGSTOP)`.

The VFIO adapter checks the submitting thread’s syscall and uses a
kprobe/kretprobe pair on the selected complete-operation wrapper. It supports
VFIO state-transition ioctls and synchronous migration-data reads and writes.

## Build on the host

Native x86-64 only. Needs kernel/module BTF, kprobes, raw/syscall tracepoints,
BPF ring buffers and signal helper support. Run in the host/root PID namespace.

Typical Debian/Ubuntu packages:

```bash
sudo apt-get install -y build-essential clang llvm pkg-config \
    libbpf-dev libelf-dev zlib1g-dev openssh-client

unzip uvp-live-fio.zip
cd uvp-live-fio
make CLANG=/usr/bin/clang
make test
```

Use distro clang with a BPF backend. The build uses libbpf CO-RE type views;
`bpftool`/generated `vmlinux.h` are not required. The running kernel needs
`/sys/kernel/btf/vmlinux`, plus relevant NVMe module BTF when the types are modular.

Outputs: `bin/uvp-daemon` and `bin/hooks.bpf.o`.

Optional system installation:

```bash
sudo make install CLANG=/usr/bin/clang
```

Keep the project directory for the supplied scripts/config. The daemon loads and
attaches the BPF programs itself. They are not permanently pinned or installed as
a kernel module. Do not run this as an unattended boot service: each instance
owns exactly one selected process, checkpoint and action.

Inspect prerequisites for the relevant wrapper:

```bash
sudo ./scripts/preflight.sh nvmevf_cmd_suspend_device
sudo ./scripts/preflight.sh nvmevf_cmd_get_ctrl_state
sudo ./scripts/preflight.sh nvmevf_cmd_set_ctrl_state
sudo ./scripts/preflight.sh nvmevf_cmd_resume_device
```

## Configure the hosts and guest workload

```bash
cp config/uvp.conf.example uvp.conf
vim uvp.conf
```

Set a new `RUN_ID`, PF controller names, target VF CNTLIDs, SSH
endpoints/key/known_hosts, and the guest test mount. The submission hook
discovers the issuing PID and TID on the trigger host.
For example, source/destination guest SSH port forwards may be 2222 and 2223 on
one host; they are examples, not discovered configuration.

`SOURCE_CONTROLLER=/dev/nvme0` means Linux host controller instance 0.
`SOURCE_CNTLID=1` means the target NVMe controller ID encoded in the migration
command. They are different identities. This program never resets that controller.

Verify passwordless SSH and passwordless `sudo -n` inside the guest beforehand.
Host keys are checked strictly; the scripts never use StrictHostKeyChecking=no.
When running under sudo, use explicit absolute key/known_hosts paths in config.
Install the real Flexible I/O Tester (`/usr/bin/fio`) inside the guest.

The test filesystem must already be mounted, writable, disposable and not the
root filesystem. The scripts do NOT create/format a filesystem. Fio only creates
`$FIO_DIR/uvp-$RUN_ID.dat`; it refuses an existing/symlinked file. Use a new run ID
and ensure free space. Old data files are not automatically deleted.

## Mode A: event-triggered fio launch (your four selectable cases)

### A1. Start your existing source and destination setup

Use your existing `source.sh` and `DEST.sh` to start the two VMs.
Destination should be listening for this migration. The source guest must still
be running for preparation. Do not begin migration until the daemon prints READY.

### A2. Prepare the source guest while it can run

```bash
./scripts/prepare-guest.sh ./uvp.conf
```

This copies the runner/settings to `/run/uvp-live-fio/$RUN_ID` inside the source
guest. No fio is started. `/run` is required to be tmpfs for the intended RAM-migration
model; the preparation script checks this. Do not separately prepare the incoming
destination: the prepared run state should arrive with the migrated VM.

### A3. Arm exactly one case on its trigger host

For case 1, on the source host:

```bash
sudo ./scripts/run-case.sh 1 ./uvp.conf | tee /tmp/uvp-tc1.log
```

After `READY`, use another terminal to execute your existing migration script:

```bash
./migrate.sh
```

For subsequent independent migrations, use fresh VM/device state as your normal
migration workflow requires and a new RUN_ID. Choose the command for the case.

```bash
sudo ./scripts/run-case.sh 2 ./uvp.conf  # source: complete Get
sudo ./scripts/run-case.sh 3 ./uvp.conf  # destination: complete Set
sudo ./scripts/run-case.sh 4 ./uvp.conf  # destination: Resume
```

Do not run these four commands for one migration. Each `run-case.sh` blocks,
waiting for its event; start migration from a separate terminal after READY.

### A4. Actual behavior

```
READY
EVENT ... testcase / TGID / TID / status / command counts / later_mask
TIMES ... kernel monotonic submission/completion/wrapper/sys_exit times
STOP_CONFIRMED
ACTION_QUEUED                     # not a guest execution acknowledgement
SIGCONT                          # host QEMU can continue
ACTION_EXEC
FIO_REQUEST                      # SSH waits for configured endpoint
STATE=RUNNING                     # actual guest acknowledgement, or DONE/failed
FIO_PID=...
START_TICKS=...
STARTED_AT=...                    # guest wall time, not host monotonic time
ACTION_ACKNOWLEDGED
```

By default, all cases send the eventual fio launch to **destination guest SSH**.
That is intentional: a source in postmigrate does not resume guest execution just
because its QEMU process received SIGCONT. Source-side cases still observe and
stop **source QEMU**, not destination QEMU.

`FIO_GUEST_SIDE=source` is available for a deliberately runnable-source setup.
It is not a way to execute fio in an otherwise paused or postmigrate source;
that configuration will time out rather than force the source VM to resume.

The worker uses bounded SSH attempts. If destination stays paused with `-S`,
your normal migration orchestration must resume it when appropriate. This project
never issues a surprise QMP `cont` to either VM.

### A5. Fetch results after fio finishes

```bash
./scripts/collect-results.sh ./uvp.conf destination
```

Inspect `final.status` for `STATE=DONE` and `FIO_EXIT=0`, plus the fio JSON/I/O logs
in `guest-results.tar.gz`. A daemon exit of zero means the launch action was
acknowledged, NOT that the migration succeeded or fio completed/error-free.

## Mode B: real source-to-destination fio continuity

This is the correct mode for "the same fio was running when migration started
and continues after migration". It deliberately starts fio **before Suspend**.

Prepare as above and arm the selected checkpoint daemon. After READY, run:

```bash
./scripts/migrate-with-fio.sh ./uvp.conf -- ./migrate.sh
```

The wrapper does only:

```
start fio on source + save boot/PID/start-ticks baseline
    -> run your existing migration command
```

At the selected checkpoint, the daemon gates/releases QEMU as before. Its later
`start-fio.sh` action finds the same run's already-launched fio instead of starting
a second one. Lost SSH acknowledgements are also protected by the guest-side
atomic `launch.lock` directory.

After destination is running, while fio is still active:

```bash
./scripts/verify-continuity.sh ./uvp.conf
./scripts/collect-results.sh ./uvp.conf destination
```

The continuity check compares run ID, boot ID, fio PID, start ticks and origin,
then checks for increased `/proc/PID/io` accounting across two destination
samples. This is observed process/I/O continuity, not proof of CRC correctness.
Run fio long enough to span migration and this check; a completed process cannot
satisfy the running-process check even if its final exit code is zero.

The default job is direct 4 KiB randrw, 30% reads, one threaded job, depth 8,
256 MiB and 300 seconds, with JSON and 1-second bandwidth/IOPS logs. It does NOT
perform checksum verification. Edit `guest/guest-fio.sh` to use your established
fio verification workload. Do not equate the sample's progress check with data
integrity or NVMe migration-state validation.

## Cross-host operation

Cases 1/2: run daemon on the source host; its destination guest SSH endpoint must
be reachable from that source host after migration.

Cases 3/4: run daemon on the destination host; preparation still targets the
running source guest. Preparation can be executed on either host if its config
routes source SSH correctly.

Use the SAME run ID/settings on both hosts. Controller instances and captured
issuer IDs are host-local. Copy `prepared.status` into `$OUTPUT_DIR/$RUN_ID/` on the daemon host
before arming; it supplies the expected guest boot ID checked before launch.
Copy `pre-migration.status` to the machine running continuity checks,
or use a shared OUTPUT_DIR, without overwriting any live guest backing storage.
The coordinator is your existing migration script; this bundle adds no new
source/destination-host RPC protocol.

## Manual daemon invocation / replacing the action

```bash
sudo ./bin/uvp-daemon \
    --case 1 --controller /dev/nvme0 --cntlid 1 \
    --bpf ./bin/hooks.bpf.o \
    --phase-symbol nvmevf_cmd_suspend_device \
    --timeout 300 --action-timeout 300 --hold-ms 200 \
    -- ./scripts/start-fio.sh ./uvp.conf
```

Everything after `--` is an argv array passed to `execvp`. The worker receives
`UVP_TESTCASE`, `UVP_ISSUER_TGID`, `UVP_ISSUER_TID` and `UVP_EPOCH`.

For the next change, usually edit only `scripts/start-fio.sh`. Edit
`guest/guest-fio.sh` for the workload, `symbols[]`/config for wrapper names,
`uvp_command_case()` for command decoding, and `on_exit()` for gate logic.

The fio command after `--` executes after SIGCONT. The UI can separately
configure a host action to run while the discovered issuer is stopped.

## Failure behavior and limits

* Attach mode uses a pidfd plus PID-generation checks. It samples all issuer TIDs
  as stopped in repeated consistent `/proc` snapshots; this is not a parent
  waitpid acknowledgement and not an atomic ptrace barrier. Run without another
  debugger, process freezer or independent SIGCONT owner. Arbitrary thread
  races/external controllers are outside the guarantee.
* The process is stopped at syscall exit, not inside NVMe completion. Ordinary
  driver work in that syscall has already happened. Signal delivery may defer.
* Coalesced later transitions observed in the same syscall are rejected.
  Cross-thread/global protocol serialization is not implemented.
* Command submission and the selected synchronous wrapper must execute in the
  same user thread and syscall. Deferred completion can execute on another CPU.
  A worker that performs the original submission on behalf of a user process
  requires another adapter to identify the issuing user thread.
* All tracked commands must succeed; a transient command error invalidates the
  checkpoint even if the driver later retries successfully.
* Reserve event before SIGSTOP; signal/map/ring failures invalidate the test.
  One-shot state prevents a second stop/action in a single daemon run.
* Ordinary failure/interrupt during a hold releases only the registered target.
  An independent watchdog releases a requested stop if the daemon dies or the
  hold exceeds 10 seconds. This is fail-open for this non-destructive fio test,
  not rollback or recovery from an uninterruptible kernel/hardware failure.
* Workers only execute after explicit release. Both action completion and the
  deadline are checked before acknowledging success. An action timeout may
  leave an already-started remote fio running; inspect its run-specific state.
* Host and guest clocks are different. Logs identify clock domains. Do not
  subtract guest wall time from host monotonic timestamps as an ordering proof.
* Test case 4 being triggered is not proof of complete migration, guest storage
  correctness or destination readiness. Those require external validation.
* No automatic deletion of fio data/results, no reset, no forced guest runstate
  changes, and no automatic restart of a failed/uncertain run.

## Troubleshooting

No READY: inspect libbpf messages. Check the actual kernel/module BTF and exact
wrapper symbol, including compiler suffixes. Existing filename/module naming is
not enough to guarantee a probeable symbol. `--debug` enables libbpf diagnostics.

READY but timeout: verify host controller instance, CNTLID, case/host,
and whether your driver executes the selected wrapper in the submitting thread’s
context. `STAT wrappers=0` suggests wrong symbol/path; submits=0 suggests the
command/device filter or request-init adapter did not match. Stats print on exit.

`later_mask != 0`: the enclosing syscall included a later migration operation.
Your requested boundary is not exposed by this sys_exit gate; do not suppress
that rejection and call it the same testcase.

STOP_CONFIRMED but no fio: first check SIGCONT, then SSH endpoint/authentication,
source guest preparation, destination VM runstate and guest runner logs. A paused
source is not expected to answer SSH. The daemon does not hold QEMU waiting for it.

`RUN_ID already exists`: choose a new ID for the next independent migration.
Do not delete a launch lock to retry an uncertain live run; that can duplicate fio.

See VALIDATION.md and SOURCES.md before hardware testing.
