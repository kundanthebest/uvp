#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Emit exactly the daemon's protocol without touching any host or device.
set -u
case_id=$1 pid=$2 checkpoint=$3 hold=$4 host=$5 guest=$6
printf 'SIMULATED: no BPF, QEMU, device reset or guest fio\nREADY pid=%s case=%s phase=demo\n' "$pid" "$case_id"
held=0
acted=0
until_second=$((SECONDS + checkpoint))
while (( SECONDS < until_second )); do
    command=
    if ! IFS= read -r -t "$((until_second-SECONDS>0?until_second-SECONDS:1))" command; then
        if (( SECONDS < until_second )); then echo 'CLEANUP: simulated control disconnected'; exit 1; fi
        break
    fi
    case "$command" in
        cancel) echo 'CLEANUP: simulated release'; exit 1;;
        trigger)
            if (( !held )); then
                printf 'EVENT simulated=1 status=0 later_mask=0 wrapper_rc=0\nSTOP_CONFIRMED pid=%s simulated=1\nHOLD_READY timeout_s=%s\n' "$pid" "$hold"
                held=1; until_second=$((SECONDS + hold)); continue
            fi;;
        action)
            if (( held && !acted )) && [[ $host != none ]]; then
                printf 'HOST_ACTION_STARTED\nSIMULATED: host action %s\n' "$host"
                sleep .2
                acted=1; echo HOST_ACTION_DONE; continue
            fi;;
        resume)
            if (( held )); then
                printf 'SIGCONT pid=%s simulated=1\n' "$pid"
                [[ $guest == none ]] || echo 'ACTION_EXEC: simulated guest readiness'
                echo 'ACTION_ACKNOWLEDGED: simulation only; no migration PASS'; exit 0
            fi;;
    esac
    echo 'CONTROL_REJECTED: invalid state or command'
done
echo 'FAIL: simulated checkpoint/hold deadline'
exit 1
