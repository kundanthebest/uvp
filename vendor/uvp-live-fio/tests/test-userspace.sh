#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for tc in 1 2 3 4; do
    "${UVP_DAEMON:-$root/bin/uvp-daemon}" --selftest --case "$tc" --hold-ms 50 -- /bin/true >"$work/tc$tc" 2>&1
    grep -q STOP_CONFIRMED "$work/tc$tc"
    grep -q ACTION_ACKNOWLEDGED "$work/tc$tc"
    awk '/SIGCONT pid=/{released=1} /ACTION_EXEC:/{if(!released) exit 1}' "$work/tc$tc"
done
echo 'PASS: four synthetic events -> stop -> queue -> SIGCONT -> worker'
"${UVP_DAEMON:-$root/bin/uvp-daemon}" --selftest --case 5 --opcode 0x06 --queue admin \
    --nsid 7 --nsid-mask 0xffffffff --cdw10 1 --cdw10-mask 0xff \
    --cdw11 0x81 --cdw11-mask 0xffff --hold-ms 50 -- /bin/true >"$work/custom" 2>&1
grep -q 'phase=custom-command wrapper=native-nvme-ioctl' "$work/custom"
grep -q ACTION_ACKNOWLEDGED "$work/custom"
for args in '--case 5 --queue admin' '--case 5 --opcode 6' \
            '--case 5 --opcode 256 --queue admin' '--case 5 --opcode 6 --queue any' \
            '--case 1 --opcode 6 --queue admin'; do
    # Intentional splitting of fixed test cases, never operator input.
    if "${UVP_DAEMON:-$root/bin/uvp-daemon}" --selftest $args -- /bin/true >"$work/invalid" 2>&1; then
        echo "FAIL: invalid selector combination accepted: $args"; exit 1
    fi
done
echo 'PASS: custom selectors parse; missing/invalid/ambiguous selectors rejected'
if "${UVP_DAEMON:-$root/bin/uvp-daemon}" --selftest --case 1 -- /bin/false >"$work/fail" 2>&1; then
    echo 'FAIL: negative action accepted'; exit 1
fi
! grep -q ACTION_ACKNOWLEDGED "$work/fail"
echo 'PASS: action failure cannot report success'
if "${UVP_DAEMON:-$root/bin/uvp-daemon}" --selftest --case 1 --action-timeout 1 -- /bin/sleep 3 >"$work/timeout" 2>&1; then
    echo 'FAIL: action deadline ignored'; exit 1
fi
! grep -q ACTION_ACKNOWLEDGED "$work/timeout"
echo 'PASS: action deadline is enforced'
"${UVP_DAEMON:-$root/bin/uvp-daemon}" --selftest --case 1 --hold-ms 3000 -- /bin/true >"$work/interrupt" 2>&1 &
pid=$!
for _ in {1..200}; do
    grep -q STOP_CONFIRMED "$work/interrupt" && break
    sleep .01
done
kill -TERM "$pid"
if wait "$pid"; then echo 'FAIL: interrupted run accepted'; exit 1; fi
! grep -q ACTION_ACKNOWLEDGED "$work/interrupt"
echo 'PASS: interruption cannot satisfy a successful testcase'
