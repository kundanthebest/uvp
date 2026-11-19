# UVP API and daemon protocol

The server listens on loopback. Use the SSH tunnel from Windows. Every `/api/` endpoint except `/api/info` requires `Authorization: Bearer TOKEN`. POST requires JSON, same origin and a body of at most 16 KiB. Tokens never go into URLs. There is no general-purpose shell execution endpoint.

| Method | Path | Result |
|---|---|---|
| GET | `/api/info` | Demo/hardware mode |
| GET | `/api/config` | Public host/action/job settings, phases and `require_prepare` |
| GET | `/api/state` | Current checkpoint, job, setup, recent events and history |
| POST | `/api/hosts` | Validate and apply source/destination connections for this session |
| POST | `/api/preflight` | Asynchronously check both hosts, destination first |
| POST | `/api/prepare` | Prepare destination, then source; verify QMP and PIDs |
| POST | `/api/runs` | Load native eBPF/daemon or explicit simulator |
| POST | `/api/jobs` | Start configured job; `migrate` requires an armed checkpoint |
| POST | `/api/runs/ID/action` | Execute the preselected host action once while held |
| POST | `/api/runs/ID/resume` | Release an idle held checkpoint |
| POST | `/api/runs/ID/cancel` | Disarm/release checkpoint, not migration rollback |
| GET | `/api/runs/ID/export` | Stored run and all its associated events |

Bodies for prepare/preflight/control endpoints are `{}`. Hosts body:

```json
{
  "source": {"address":"192.0.2.10","user":"uvp","ssh_port":22,"pid":0,"controller":"/dev/nvme0","cntlid":1},
  "destination": {"address":"192.0.2.20","user":"uvp","ssh_port":22,"pid":0,"controller":"/dev/nvme0","cntlid":2}
}
```

These are documentation IPs. Actual two-PC migration with the included script requires unicast IPv4. Save host/device selections before preparation. The UI does not supply executable paths or SSH keys; those remain trusted server configuration.

Arm body for reset after source Suspend:

```json
{
  "case":1,"pid":12345,"controller":"/dev/nvme0","cntlid":1,
  "hold_seconds":120,"checkpoint_seconds":300,
  "host_action":"source-nvme-reset","guest_action":"none",
  "automatic":true,"auto_resume":true
}
```

The action must be enabled in server configuration. `automatic` defaults to false for API compatibility; the UI explicitly selects true. `auto_resume` defaults to true and applies to automatic mode. For a destructive profile, also send `destructive_ack` equal to its configured `confirmation`, or `controller:NSID`. The supplied hardware profile requires preparation; cases 1–4 must use the PID/controller/CNTLID verified by preparation.

Case 5 adds `target_host` and explicit selectors, for example:

```json
{
  "case":5,"target_host":"source","pid":12345,
  "controller":"/dev/nvme0","cntlid":1,
  "selectors":{"opcode":"0x06","queue":"admin","nsid":0,"nsid_mask":0,"cdw10":1,"cdw10_mask":"0xff","cdw11":0,"cdw11_mask":0},
  "host_action":"none","automatic":true,"auto_resume":false
}
```

Generic matching supports the synchronous paths documented in [GENERIC_HOOKS.md](GENERIC_HOOKS.md). Zero masks are wildcards. A server-controlled `hosts.SIDE.symbols["5"]` may name an audited synchronous wrapper. Browser text cannot choose an arbitrary symbol.

Start migration with `{"job":"migrate"}` only after `ARMED`. The controller sends the destination IP and expected source PID to the source host bridge. It records script status separately from the checkpoint. Migration preparation is consumed at start: prepare again after restoring the VM/device setup for another run.

## State interpretation

Checkpoint states: `STARTING → ARMED → PAUSED → HOST_ACTION → PAUSED → RESUMING → RELEASED → DONE`. Action/no-action/manual paths may omit states. Failure/cancellation yields `FAILED`, `CANCELLED`, or `INTERRUPTED` after server restart.

`setup.status` is `IDLE`, `CHECKING`, `CHECKED`, `PREPARING`, `READY`, `FAILED` or `CONSUMED`. `CHECKED` does not mean prepared. Host settings and preparation cannot change during a live checkpoint/job. Preparation returns asynchronously; poll state.

`migration_script_status` reports `NOT STARTED`, `RUNNING`, `DONE`, `FAILED`, `TIMEOUT` or `SIMULATED`. `migration_result` remains `NOT VERIFIED`; a script return code does not establish guest data integrity. `DONE` on a checkpoint means the stop/action/release cycle completed.

Typical HTTP errors: 400 invalid selector/profile, 401 bad token, 403 origin/Host rejected, 404 unknown route/run, 409 conflicting/stale state, 413 oversized/missing body, 415 wrong content type, 500 launch/runtime failure. After a connection error on a mutation, read state before retrying.

## Local daemon control

The controller owns a local/SSH stdin stream to the C daemon. The daemon reports machine-control stdout such as `READY`, `HOLD_READY`, `HOST_ACTION_STARTED`, `HOST_ACTION_DONE` and `SIGCONT`. Action output is redirected to stderr so it cannot masquerade as these events.

After `HOLD_READY`, stdin accepts `action`, `resume`, or `cancel`, one per line. The daemon owns its pidfd and verifies the group stop. EOF, action failure and bounded timeout invoke cleanup; the watchdog provides emergency release if the daemon dies. Cleanup release is not test success or rollback.
