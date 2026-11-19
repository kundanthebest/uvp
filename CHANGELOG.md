# Changes — 2026-11-19

- Added two-host UI connection settings, preflight and destination-before-source preparation with verified QMP/PID identity.
- Added automatic action execution and optional automatic process release after successful selected NVMe command completion.
- Added generic synchronous NVMe opcode, queue, NSID and CDW10/CDW11 selectors while retaining the existing migration wrappers.
- Added a fixed host bridge, source/destination/migration wrappers, installer, Windows tunnel helper, GitHub publishing helper and deployment guide.
- Included the existing repeat-safe v3 migration script unchanged.
- Added namespace deletion profiles with an explicit configured NSID and target acknowledgement.
- Added failure/state-machine tests, native compilation checks and GitHub CI configuration.

Hardware QEMU/kernel patches and machine-specific source/destination launchers remain prerequisites. See VALIDATION.md for exact test scope.
