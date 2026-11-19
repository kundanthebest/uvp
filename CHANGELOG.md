# Changes

## Automatic discovery of the NVMe command issuer

- Arming takes the host, controller and command selector. The submission hook captures the first matching request’s TGID and TID. The completion hook uses the saved request identity, and only the submitting thread can trigger the stop at syscall exit.
- The UI, run export and daemon events report the captured issuer. Migration preparation continues to verify the source and destination QEMU processes through QMP.
- The daemon and eBPF object use ABI version 3. Rebuild and deploy both on each trigger host.

## Native controller and shell orchestration

- Replaced the Linux HTTP service with a loopback C server. The server-rendered HTML forms work in a Windows browser with JavaScript disabled.
- Moved host preparation, checkpoint sequencing, event recording, SSH transport and action dispatch to Bash and native helpers.
- Moved host preflight and the privileged bridge to shell with native QMP peer identification. The release continues to use the supplied repeat-safe v3 migration script and C/libbpf/eBPF implementation.
- Added controller and host tests in shell/C and a Bash builder for the optional offline dashboard.

## Two-host command and action workflow

- Added destination-first preparation with verified QMP/PID identity and command-triggered automatic or manual action/release.
- Added custom synchronous opcode, queue, NSID, CDW10 and CDW11 selectors alongside the four migration wrappers.
- Added host installation, Windows SSH tunnel support, and explicit profile/target confirmation for disposable namespace deletion.
