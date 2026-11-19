#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Author: Kundan Kumar <kundan.kumar@samsung.com>
# Inject one lost NVMe I/O completion using Linux fail_io_timeout.
# Arms a completion-loss injection only. Recovery may reset the controller.
# No kernel or driver build is performed. No data is written to the disk.
# Sources: docs.kernel.org/fault-injection/fault-injection.html
# Linux: block/blk-timeout.c, drivers/nvme/host/nvme.h and pci.c
set -Eeuo pipefail

usage() {
    cat <<'HELP'
Usage: sudo bash inject_one_timeout_nvme1n1.sh [--status|--disarm]

Default: arm one completion-loss injection on nvme1n1 and exit. No dd is run.
A direct read in another terminal, already running or started later, triggers it.
--status: inspect the budget. --disarm: restore original saved settings.
Run again after consumption and recovery to arm another timeout.
An unconsumed budget is not overwritten. Do not mix with other injectors.
Queue timeout is 30000 ms; already-started requests may retain the old timeout.
Requires existing CONFIG_FAIL_IO_TIMEOUT and fault-injection debugfs support.
Supports PCI NVMe or a native multipath head with one controller path.

Settings intentionally persist after exit. Use --disarm after testing.
Disarming cannot cancel recovery of a request whose completion was suppressed.
Use a lab controller: reset can affect all namespaces on that controller.
dd may stall then succeed after recovery; a userspace error is not guaranteed.
Use one synchronous dd stream to isolate one completion. times=1 is a global
budget, not a command selector; highly concurrent completions can race.
State is saved under /run/uvp-nvme1n1-timeout until disarm or reboot.
Exit 0 means the requested operation succeeded, not that recovery succeeded.
HELP
}
action=${1:---arm}
case "$action" in
    --help|-h) usage; exit 0 ;;
    --arm|--status|--disarm) ;;
    *) usage >&2; exit 1 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 1; }
umask 077
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 ]] || die 'Run with sudo bash inject_one_timeout_nvme1n1.sh'
for cmd in basename cat dirname flock getconf mkdir mount mountpoint readlink rm; do
    command -v "$cmd" >/dev/null || die "Missing command: $cmd"
done

disk=nvme1n1
dev=/dev/$disk
fi=/sys/kernel/debug/fail_io_timeout
timeout_ms=30000
state=/run/uvp-nvme1n1-timeout

# Coordinate concurrent copies of this script; other injectors must remain idle.
exec 9>/run/lock/uvp-fail-io-timeout.lock
flock -n 9 || die 'Another UVP timeout-injection run holds the lock.'
mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug
[[ -d $fi ]] || die 'fail_io_timeout is unavailable. Check CONFIG_FAIL_IO_TIMEOUT=y and CONFIG_FAULT_INJECTION_DEBUG_FS=y in the running kernel.'

write_attr() { printf '%s\n' "$2" > "$1"; }
load_state() {
    [[ -f $state/ready ]] || die "Incomplete saved state in $state; inspect before continuing."
    queue=$(cat "$state/queue")
    [[ $queue == /sys/class/block/nvme* ]] || die 'Invalid saved queue path.'
    gate=$queue/io-timeout-fail
    timer=$queue/queue/io_timeout
}
same_queue() {
    [[ -e $gate && -e $timer ]] || return 1
    [[ $(readlink -f "$queue") == "$(cat "$state/real_queue")" ]] || return 1
    if [[ -f $state/diskseq ]]; then
        [[ -r $queue/diskseq ]] || return 1
        [[ $(cat "$queue/diskseq") == "$(cat "$state/diskseq")" ]] || return 1
    fi
}
restore() {
    local f key failed=0
    write_attr "$fi/probability" 0 || failed=1
    write_attr "$fi/times" 0 || failed=1
    if same_queue; then
        write_attr "$gate" "$(cat "$state/gate")" || failed=1
        write_attr "$timer" "$(cat "$state/timeout")" || failed=1
    else
        echo 'Queue disappeared or changed; queue settings not restored.' >&2
        failed=1
    fi
    for f in "$state"/attrs/*; do
        key=${f##*/}
        [[ $key != probability ]] || continue
        write_attr "$fi/$key" "$(cat "$f")" || failed=1
    done
    write_attr "$fi/probability" "$(cat "$state/attrs/probability")" || failed=1
    if (( failed )); then
        echo "Saved state retained in $state for manual recovery." >&2
        return 1
    fi
    rm -r -- "$state"
}
if [[ $action == --status ]]; then
    if [[ ! -d $state ]]; then
        echo 'No saved session for nvme1n1.'
    else
        load_state
        printf 'Queue: %s\n' "$queue"
        if same_queue; then
            printf 'io-timeout-fail=%s io_timeout=%s ms\n' "$(cat "$gate")" "$(cat "$timer")"
        else
            echo 'WARNING: target queue disappeared or changed.'
        fi
    fi
    printf 'Global probability=%s times=%s\n' "$(cat "$fi/probability")" "$(cat "$fi/times")"
    echo 'In an unchanged session: times=1 is pending; times=0 means consumed. Confirm recovery in dmesg.'
    exit 0
fi
if [[ $action == --disarm ]]; then
    [[ -d $state ]] || { echo 'No saved session; no settings changed.'; exit 0; }
    load_state
    restore || exit 1
    echo 'Disarmed; original settings restored. Existing recovery may continue.'
    exit 0
fi
[[ -b $dev ]] || die "$dev is not a block device."

queue=/sys/class/block/$disk
real_queue=$(readlink -f "$queue")
# Native NVMe multipath uses a separate request queue for each controller path.
if [[ $real_queue == */virtual/nvme-subsystem/* ]]; then
    shopt -s nullglob
    paths=(/sys/class/block/"${disk%n*}"c*n"${disk##*n}")
    shopt -u nullglob
    [[ ${#paths[@]} == 1 ]] || die 'Multiple or no controller paths found for nvme1n1; this test requires one path to target one request queue reliably.'
    queue=${paths[0]}
    real_queue=$(readlink -f "$queue")
fi
controller=$(basename "$(dirname "$real_queue")")
[[ $controller =~ ^nvme[0-9]+$ ]] || die "Cannot determine controller from $real_queue"
[[ $(cat "/sys/class/nvme/$controller/transport") == pcie ]] || die 'This script is for the NVMe PCI transport.'
[[ $(cat "/sys/class/nvme/$controller/state") == live ]] || die 'Controller not live; wait for recovery.'
gate=$queue/io-timeout-fail
timer=$queue/queue/io_timeout
[[ -r $gate && -w $gate && -r $timer && -w $timer ]] || die "Required queue attributes are unavailable under $queue"

# The saved session permits rearming after consumption, preserving originals.
if [[ -d $state ]]; then
    [[ $(cat "$state/queue") == "$queue" ]] || die 'Saved queue differs; use --disarm first.'
    load_state
    same_queue || die 'Queue identity changed; inspect the saved state.'
    [[ $(cat "$fi/probability") == 100 && $(cat "$gate") == 1 ]] || die 'Session changed externally; use --disarm first.'
    [[ $(cat "$fi/times") == 0 ]] || die 'One injection is still pending; no additional timeout armed.'
else
    [[ $(cat "$fi/probability") == 0 ]] || die 'Global injector already active; finish that experiment first.'
fi
for path in /sys/class/block/*/io-timeout-fail; do
    [[ -f $path ]] || continue
    [[ -d $state && $(readlink -f "$path") == "$(readlink -f "$gate")" ]] && continue
    [[ $(cat "$path") == 0 ]] || die "Another queue is opted in: $path"
done

attrs=(probability times interval space verbose task-filter)
for key in stacktrace-depth require-start require-end reject-start reject-end; do
    [[ ! -e $fi/$key ]] || attrs+=("$key")
done
for key in "${attrs[@]}"; do
    [[ -r $fi/$key && -w $fi/$key ]] || die "Cannot access $fi/$key"
done
# Snapshot once. Never source saved state as shell code.
if [[ ! -d $state ]]; then
    mkdir -m 700 "$state"
    mkdir -m 700 "$state/attrs"
    printf '%s\n' "$queue" > "$state/queue"
    printf '%s\n' "$real_queue" > "$state/real_queue"
    cat "$timer" > "$state/timeout"
    cat "$gate" > "$state/gate"
    [[ ! -r $queue/diskseq ]] || cat "$queue/diskseq" > "$state/diskseq"
    for key in "${attrs[@]}"; do cat "$fi/$key" > "$state/attrs/$key"; done
    printf '1\n' > "$state/ready"
fi
committed=0
on_exit() {
    local rc=$?
    trap - EXIT
    if (( ! committed )); then
        echo 'Setup failed or interrupted; restoring original settings.' >&2
        restore || rc=1
    fi
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

write_attr "$fi/probability" 0
write_attr "$fi/times" 0
write_attr "$timer" "$timeout_ms"
[[ $(cat "$timer") == "$timeout_ms" ]] || die 'Could not set a 30000 ms queue timeout.'
write_attr "$fi/interval" 1
write_attr "$fi/space" 0
write_attr "$fi/task-filter" 0
write_attr "$fi/verbose" 1
# Reset optional stack filters as well as their depth.
for key in require-start reject-start reject-end stacktrace-depth; do
    [[ ! -e $fi/$key ]] || write_attr "$fi/$key" 0
done
if [[ -e $fi/require-end ]]; then
    if [[ $(getconf LONG_BIT) == 64 ]]; then
        write_attr "$fi/require-end" 0xffffffffffffffff
    else
        write_attr "$fi/require-end" 0xffffffff
    fi
fi
write_attr "$gate" 1
write_attr "$fi/times" 1
write_attr "$fi/probability" 100  # Arm last; running I/O may consume immediately.
committed=1                       # Successful exit must leave injection armed.
printf 'Armed one timeout: device=%s queue=%s controller=%s\n' "$dev" "$queue" "$controller"
printf 'Configured times=1 probability=100 timeout=30000 ms; current times=%s\n' "$(cat "$fi/times")"
echo 'No I/O submitted. Another terminal can run dd now or already be running it.'
echo 'Use --status to inspect; --disarm to restore original settings after recovery.'
