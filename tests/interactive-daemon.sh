#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Interact with the test-only daemon. Its self-test child is the only signal target.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bin=$root/build/uvp-daemon-selftest
temp=$(mktemp -d)
pid=
log=$temp/log
cleanup() {
    if [[ -n $pid ]]; then
        kill -TERM "$pid" 2>/dev/null || :
        wait "$pid" || :
    fi
    rm -rf -- "$temp"
}
trap cleanup EXIT
fail() { cat "$log" >&2; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
until_line() {
    local deadline=$((SECONDS + 8))
    until grep -Eq "^$1" "$log"; do
        if ! kill -0 "$pid" 2>/dev/null || ((SECONDS >= deadline)); then fail "missing $1"; fi
        sleep .02
    done
}
start() {
    local seconds=$1
    shift
    rm -f "$temp/control"
    mkfifo "$temp/control"
    # The child opens only the reading end. Closing fd 3 in the parent must
    # deliver real EOF to the daemon even while the watchdog is still alive.
    "$bin" --selftest --case 1 --control-stdin --hold-timeout "$seconds" --action-timeout 5 "$@" <"$temp/control" >"$log" 2>&1 &
    pid=$!
    exec 3>"$temp/control"
    until_line HOLD_READY
}
finish() {
    local expect=$1 result=0
    wait "$pid" || result=$?
    pid=
    exec 3>&-
    if [[ $expect == success ]]; then ((result == 0)) || fail 'daemon failed'
    else ((result != 0)) || fail 'daemon reported success'; fi
}
send_control() { printf '%s\n' "$1" >&3; }
cat >"$temp/record-issuer" <<'ACTION'
#!/bin/sh
printf '%s %s\n' "$UVP_ISSUER_TGID" "$UVP_ISSUER_TID" > "$1"
ACTION
chmod +x "$temp/record-issuer"
start 8 --host-action-program "$temp/record-issuer" --host-action-arg "$temp/host" -- "$temp/record-issuer" "$temp/guest"
[[ ! -e $temp/host && ! -e $temp/guest ]] || fail 'action ran before request'
send_control action
until_line HOST_ACTION_DONE
[[ -f $temp/host && ! -e $temp/guest ]] || fail 'host or guest action order'
send_control action
until_line CONTROL_REJECTED
send_control resume
finish success
[[ -f $temp/guest ]] || fail 'post-release action missing'
identity=$(sed -nE 's/^EVENT .* tgid=([0-9]+) tid=([0-9]+) .*/\1 \2/p' "$log")
[[ -n $identity && $(cat "$temp/host") == "$identity" && $(cat "$temp/guest") == "$identity" ]] || fail 'action received wrong issuer'
awk '/^SIGCONT pid=/{released=1} /^ACTION_EXEC:/{if(!released) exit 1; ran=1} END {if(!ran) exit 1}' "$log" || fail 'wrong release order'

start 8 --host-action-program /bin/false -- /bin/true
send_control action
finish failure
grep -q '^CLEANUP: SIGCONT' "$log" || fail 'host failure did not release target'
start 8 -- /bin/true
exec 3>&-
finish failure
grep -q '^CLEANUP: SIGCONT' "$log" || fail 'EOF did not release target'
start 8 --host-action-program /bin/sleep --host-action-arg 25 -- /bin/true
send_control action
until_line HOST_ACTION_STARTED
send_control cancel
finish failure
start 1 -- /bin/true
finish failure
grep -q 'hold deadline' "$log" || fail 'hold deadline missing'
if "$bin" --case 1 --controller /dev/nvme0 --cntlid 1 -- /bin/true >"$log" 2>&1; then fail 'test-only binary accepted real target'; fi
grep -q 'test-only binary' "$log" || fail 'test restriction missing'
if "$bin" --selftest --pid "$$" --case 1 -- /bin/true >"$log" 2>&1; then fail 'accepted a supplied target'; fi
grep -q -- "--pid" "$log" || fail 'unexpected error for removed PID option'
echo 'PASS: interactive daemon action ordering, EOF, cancellation, timeout and target restrictions'
