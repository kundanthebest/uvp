#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Default daemon action. Edit this script to implement the next userspace action.
source "$(dirname "$0")/common.sh"
load_config "${1:?Usage: start-fio.sh config [source|destination] [origin]}"
side=${2:-${FIO_GUEST_SIDE:-destination}}
origin=${3:-event-tc${UVP_TESTCASE:-manual}}
[[ $GUEST_WAIT_SECONDS =~ ^[0-9]+$ && $GUEST_WAIT_SECONDS -gt 0 ]] || exit 2
[[ -f $RUN_DIR/prepared.status ]] || {
    echo "Missing local prepared.status; copy it from preparation host first" >&2; exit 2;
}
expected_boot=$(kv BOOT_ID < "$RUN_DIR/prepared.status")
[[ $expected_boot =~ ^[A-Za-z0-9-]+$ ]] || exit 2
deadline=$((SECONDS + GUEST_WAIT_SECONDS))
echo "FIO_REQUEST run=$RUN_ID endpoint=$side origin=$origin"
while (( SECONDS < deadline )); do
    rc=0
    out=$(guest_exec "$side" sudo -n "/run/uvp-live-fio/$RUN_ID/guest-fio.sh" \
        start "$RUN_ID" "$origin" "$expected_boot" </dev/null 2>"$RUN_DIR/ssh-last-error.log") || rc=$?
    # Do not accept a late response as an on-time success.
    (( SECONDS < deadline )) || break
    if (( rc == 0 )); then
        state=$(kv STATE <<< "$out")
        if [[ $state == RUNNING ]]; then
            printf '%s\n' "$out" | tee "$RUN_DIR/action.status"
            echo "FIO_ACK: process observed; not yet a workload-completion/continuity PASS"
            exit 0
        elif [[ $state == DONE ]]; then
            printf '%s\n' "$out" | tee "$RUN_DIR/action.status"
            [[ $(kv FIO_EXIT <<< "$out") == 0 ]] || exit 1
            echo "FIO_ACK: job already finished successfully; continuity not established"
            exit 0
        elif [[ $state == LOST ]]; then
            echo "Guest lost the registered fio process" >&2; exit 1
        fi
    elif (( rc == 70 )); then
        echo "Guest identity/run preparation missing; refusing another guest" >&2; exit 1
    fi
    sleep 1
done
echo "FAIL: guest fio did not acknowledge before deadline; QEMU was already released" >&2
exit 1
