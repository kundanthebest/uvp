# Validation

The repository has a hardware-independent suite for the controller and daemon. GitHub Actions builds the production Linux artifacts, runs the tests, and records the result against the exact commit. [Build and test runs](https://github.com/kundanthebest/uvp/actions/workflows/tests.yml)

| What to check | How to reproduce |
|---|---|
| Native HTTP service and helpers | `make controller` |
| Native libbpf daemon and BPF object | Install the hardware build dependencies, then run `make build CLANG=/usr/bin/clang` |
| Controller API, run transitions, host identity, action/release and recovery cases | `make test` |
| Offline dashboard, including automatic, manual and cancelled runs | `bash demo/build.sh && node demo/check.cjs` |
| Installed file integrity against the release | Run `sha256sum --check --quiet SHA256SUMS` from the checkout root |

The daemon’s synthetic tests use disposable child processes and mocked host/guest actions. They exercise command matching, group-stop observation, release ordering, failure, deadlines and SIGKILL watchdog recovery. The offline dashboard test runs its simulation with a deterministic clock. Local execution environments that block sockets can prevent a loopback HTTP or Unix QMP test from running. Check the test output for each environment.

## Lab validation

Live attachment to your kernel, CO-RE relocations, vendor wrapper names, patched QEMU behavior, real NVMe resets/deletions, and data integrity across two physical PCs need a lab run. The stock examples contain placeholder devices, addresses, namespace IDs and executable paths.

1. Run preflight and prepare both hosts with your known-good VM setup. Verify the QMP peer, source `running` and destination `inmigrate`.
2. Choose source Suspend with the no-op profile for the first checkpoint. Arm the daemon, wait for `ARMED`, then launch migration.
3. Compare UVP’s stop, action and release events with both QEMU logs and migration-script output. Verify guest I/O on the destination.
4. Repeat with the configured reset or disposable namespace profile. Record the checkpoint result, script result and data-integrity result individually.

The provided `DONE` status describes the checkpoint cycle. A completed migration script still requires a destination-side guest/workload check. [Detailed deployment and recovery](docs/DEPLOYMENT.md)
