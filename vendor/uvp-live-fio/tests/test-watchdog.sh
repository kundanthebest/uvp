#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
target= daemon=
cleanup() {
    [[ -z $daemon ]] || kill -KILL "$daemon" 2>/dev/null || true
    [[ -z $target ]] || kill -KILL "$target" 2>/dev/null || true
    rm -rf "$tmp"
}
trap cleanup EXIT

wait_line() {
    local pattern=$1
    for _ in {1..300}; do
        grep -q "^$pattern" "$tmp/log" && return
        sleep .02
    done
    cat "$tmp/log" >&2
    return 1
}

for stage in before-submit before-event confirmed; do
    UVP_SELFTEST_PAUSE_AT=$stage "${UVP_DAEMON:-$root/bin/uvp-daemon}" \
        --selftest --case 1 --hold-ms 5000 -- /bin/true >"$tmp/log" 2>&1 &
    daemon=$!
    if [[ $stage == confirmed ]]; then
        wait_line STOP_CONFIRMED
        target=$(sed -nE 's/^STOP_CONFIRMED pid=([0-9]+) .*/\1/p' "$tmp/log")
    else
        wait_line "SELFTEST_PAUSED stage=$stage"
        target=$(sed -nE 's/^SELFTEST_PAUSED stage=[^ ]+ child=([0-9]+)$/\1/p' "$tmp/log")
    fi
    [[ $target =~ ^[1-9][0-9]*$ ]]
    kill -KILL "$daemon"
    wait "$daemon" 2>/dev/null || true
    daemon=
    if [[ $stage == before-submit ]]; then
        wait_line 'WATCHDOG: disarmed'
        if grep -Eq '^EVENT|^WATCHDOG: releasing' "$tmp/log"; then exit 1; fi
    else
        wait_line "WATCHDOG: releasing submission issuer tgid=$target"
        if [[ $stage == before-event ]] && grep -q '^EVENT' "$tmp/log"; then exit 1; fi
    fi
    for _ in {1..200}; do
        [[ $(awk '/^State:/{print $2}' "/proc/$target/status") != T ]] && break
        sleep .02
    done
    [[ $(awk '/^State:/{print $2}' "/proc/$target/status") != T ]]
    kill -KILL "$target"
    target=
done

UVP_SELFTEST_PAUSE_AT=before-submit "${UVP_DAEMON:-$root/bin/uvp-daemon}" \
    --selftest --case 1 -- /bin/true >"$tmp/log" 2>&1 &
daemon=$!
wait_line 'SELFTEST_PAUSED stage=before-submit'
target=$(sed -nE 's/^SELFTEST_PAUSED stage=[^ ]+ child=([0-9]+)$/\1/p' "$tmp/log")
kill -TERM "$daemon"
kill -CONT "$daemon"
if wait "$daemon"; then echo 'FAIL: cancelled arm reported success' >&2; exit 1; fi
daemon=
target=
wait_line 'WATCHDOG: disarmed'
if grep -Eq '^EVENT|^WATCHDOG: releasing' "$tmp/log"; then exit 1; fi
echo 'PASS: cancel/revoke before submission, watchdog release before event delivery and during hold'
