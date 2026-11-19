#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Exercise the production hooks on a fresh nvme-loop controller with no namespaces.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
daemon=$root/vendor/uvp-live-fio/bin/uvp-daemon
obj=$root/vendor/uvp-live-fio/bin/hooks.bpf.o
skip() { echo "SKIP: $*" >&2; exit 77; }
[[ $EUID == 0 && $(uname -m) == x86_64 ]] || skip "requires root on x86-64 Linux"
[[ -e /sys/kernel/btf/vmlinux ]] || skip "kernel BTF unavailable"
modprobe nvme-loop || skip "running kernel lacks the nvme-loop transport"
[[ -d /sys/kernel/config/nvmet/ports ]] || skip "mount configfs on /sys/kernel/config"
[[ -x $daemon && -f $obj ]] || { echo "Build production artifacts with make build" >&2; exit 1; }

tmp=$(mktemp -d)
uuid=$(cat /proc/sys/kernel/random/uuid)
nqn=nqn.2014-08.org.nvmexpress:uuid:$uuid
cfg=/sys/kernel/config/nvmet
sub=$cfg/subsystems/$nqn
port= ctrl= daemon_pid= issuer_pid=
find_ctrl() {
    local path
    for path in /sys/class/nvme/nvme[0-9]*; do
        if [[ -f $path/subsysnqn && $(<"$path/subsysnqn") == "$nqn" && $(<"$path/transport") == loop ]]; then
            printf '%s\n' "$path"; return 0
        fi
    done
    return 1
}
cleanup() {
    local rc=$?
    trap - EXIT
    set +e
    if [[ $daemon_pid ]]; then kill -TERM "$daemon_pid" 2>/dev/null || :; wait "$daemon_pid" || :; fi
    if [[ $issuer_pid ]]; then kill -KILL "$issuer_pid" 2>/dev/null || :; wait "$issuer_pid" || :; fi
    if ctrl=$(find_ctrl); then echo 1 > "$ctrl/delete_controller"; fi
    if [[ $port ]]; then rm -f -- "$port/subsystems/$nqn"; rmdir -- "$port"; fi
    rmdir -- "$sub" 2>/dev/null || :
    if ((rc)); then cat "$tmp"/{daemon,issuer}.log 2>/dev/null || :; fi
    rm -rf -- "$tmp"
    exit "$rc"
}
trap cleanup EXIT
"${CC:-cc}" -Wall -Wextra -Werror -O2 -pthread "$root/tests/identify-thread.c" -o "$tmp/identify"
mkdir -- "$sub"
echo 1 > "$sub/attr_allow_any_host"
for ((i=20000; i<21000; i++)); do
    if mkdir -- "$cfg/ports/$i" 2>/dev/null; then port=$cfg/ports/$i; break; fi
done
[[ $port ]] || { echo 'No free test port' >&2; exit 1; }
echo loop > "$port/addr_trtype"
ln -s -- "$sub" "$port/subsystems/$nqn"
printf 'transport=loop,nqn=%s' "$nqn" > /dev/nvme-fabrics
for ((i=0; i<100; i++)); do
    if ctrl=$(find_ctrl) && [[ -c /dev/${ctrl##*/} ]]; then break; fi
    sleep .05
done
[[ $ctrl && -c /dev/${ctrl##*/} ]]
dev=/dev/${ctrl##*/}
"$daemon" --case 5 --queue admin --opcode 0x06 --cdw10 1 --cdw10-mask 0xffffffff \
    --controller "$dev" --bpf "$obj" --timeout 12 --hold-ms 100 --ready-file "$tmp/ready" \
    -- /bin/true >"$tmp/daemon.log" 2>&1 &
daemon_pid=$!
for ((i=0; i<200; i++)); do
    [[ -f $tmp/ready ]] && break
    kill -0 "$daemon_pid" || exit 1
    sleep .05
done
[[ -f $tmp/ready ]]
"$tmp/identify" "$dev" > "$tmp/issuer.log" 2>&1 &
issuer_pid=$!
rc=0
wait "$daemon_pid" || rc=$?
daemon_pid=
(( rc == 0 )) || exit "$rc"
expected=$(head -1 "$tmp/issuer.log")
[[ $expected =~ ^tgid=([0-9]+)\ tid=([0-9]+)$ ]]
[[ ${BASH_REMATCH[1]} == "$issuer_pid" && ${BASH_REMATCH[1]} != "${BASH_REMATCH[2]}" ]]
grep -F " $expected " "$tmp/daemon.log" | grep -F 'submit=1 complete=1 syscall=16 ret=0'
grep -F "STOP_CONFIRMED pid=$issuer_pid " "$tmp/daemon.log"
grep -F "SIGCONT pid=$issuer_pid " "$tmp/daemon.log"
wait "$issuer_pid"
issuer_pid=
echo 'PASS: live nvme-loop Identify completed and the submission thread and process matched at sys_exit'
