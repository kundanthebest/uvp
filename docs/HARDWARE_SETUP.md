# Hardware setup and guest workloads

Use the two-host deployment guide for the source, destination, and Linux controller. It includes installation commands, the root-owned host configuration, QMP checks, Windows tunnel, and reset-after-Suspend walkthrough. [Two-host deployment](DEPLOYMENT.md)

## Optional guest fio jobs

The guest scripts in `vendor/uvp-live-fio/` can launch fio before migration or after the host process has been released. For an optional guest workload, copy `vendor/uvp-live-fio/config/uvp.conf.example` to `config/uvp.conf` and configure the existing guest SSH endpoints, identity, dedicated data directory, controller IDs and a new `RUN_ID`. Keep a foreground host action short enough for the hold deadline.

The controller’s JSON config selects jobs and actions. The Bash `uvp.conf` describes the guest lab to those scripts. An operator who enables destination-side work must make the configuration, credentials, and prepared run markers available to the launcher on the destination. Verify guest access from the daemon host. [Guest test setup](../vendor/uvp-live-fio/README.md)

## Choosing an action

A host profile specifies a program and argument vector and a trigger host. The daemon runs it while the selected issuer is stopped. Post-release guest jobs require the guest to be runnable. For namespace deletion, set the controller and NSID in both the profile and its arguments, and acknowledge the displayed target before arming. An NVMe reset or deletion can alter storage even if migration ultimately fails.

Compare each device/VM mapping and symbol to the working migration setup. Select the custom opcode gate only for a supported synchronous issuer. [Command hook compatibility](GENERIC_HOOKS.md)
