#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Local validation, disposable subprocesses and QMP Unix sockets only.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
source "$root/scripts/host-bridge.sh"
source "$root/scripts/host-action.sh"
temp=$(mktemp -d)
peer=''
cleanup_test() {
    if [[ -n $peer ]]; then kill "$peer" 2>/dev/null || :; wait "$peer" 2>/dev/null || :; fi
    rm -rf "$temp"
}
trap cleanup_test EXIT
reject() { if "$@" >/dev/null 2>&1; then printf 'Unexpected success: %s\n' "$*" >&2; exit 1; fi; }
for good in 1 7 4294967294; do valid_nsid "$good"; done
for bad in 0 -1 4294967295 4294967296 081 2.5 2e3 99999999999999999999 '--all'; do reject valid_nsid "$bad"; done
for good in 192.0.2.2 10.12.14.5 127.0.0.1; do valid_ipv4 "$good"; done
for bad in 0.0.0.0 224.0.0.1 239.255.255.255 255.255.255.255 10.0.0.01 300.1.1.1 127.1 '1;echo'; do reject valid_ipv4 "$bad"; done
if [[ $(stat -c %u /usr/bin/bash) == 0 && $(stat -c %u /) == 0 ]]; then
    trusted_file /bin/bash executable >/dev/null
fi
reject trusted_file "$temp"
reject trusted_chain /run/../etc/abc no
test "$(jq -r '.role' "$root/config/host-source.example.json")" = source
# Source a temporary config only in this test process; installed entry points
# always use /etc/uvp/host.json and enforce ownership on the whole path.
(
    config=$temp/host.json
    cp "$root/config/host-source.example.json" "$config"
    trusted_file() { printf '%s\n' "$1"; }
    trusted_chain() { return 0; }
    load_config
    test "${launch[1]}" = /opt/uvp-migration/source.sh
    test "${migration[0]}" = /bin/bash
    jq '.environment.PATH="/tmp"' "$config" >"$temp/bad.json"
    config=$temp/bad.json
    reject_from_subshell() { ( load_config ); }
    reject reject_from_subshell
)
# Exercise the host handoff itself with an inert migration program. The
# destination address is a literal argv element and SOURCE_QMP comes from
# the local configuration even when the environment supplied a different one.
(
    role=destination controller=/dev/nvme8 cntlid=3 launch_timeout=1
    preflight() { echo '{"ok":true}'; }
    inspect_vm() { echo '{"pid":112,"qmp_status":"inmigrate"}'; }
    prepare | jq -e '.ok and (.launched==false) and .pid==112 and .role=="destination"' >/dev/null
    request=$temp/request.json
    jq -n '{destination_ip:"192.0.2.10",expected_pid:112}' >"$request"
    as_subshell() { ( migrate ); }
    reject as_subshell
    role=source qmp=/run/uvp-test.qmp migration_timeout=5
    inspect_vm() { echo '{"pid":112,"qmp_status":"running"}'; }
    env_entries=(SOURCE_QMP=/wrong/path)
    migration=(/bin/bash -c 'printf "%s\n%s\n" "$SOURCE_QMP" "$1" >"$0"' "$temp/received")
    migrate >/dev/null
    [[ $(cat "$temp/received") == $'/run/uvp-test.qmp\n192.0.2.10' ]]
    jq -n '{destination_ip:"192.0.2.10",expected_pid:113}' >"$request"
    reject as_subshell
    jq -n '{destination_ip:"192.0.2.10; echo hello",expected_pid:112}' >"$request"
    reject as_subshell
)
# Check process identity even when the sandbox disables Unix sockets.
reject "$root/build/uvp-qmp" "$temp/socket" "$$" /unrelated/executable
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror "$root/tests/qmp-peer.c" -o "$temp/peer"
start_peer() {
    rm -f "$temp/socket"
    "$temp/peer" "$temp/socket" & peer=$!
    for _ in {1..100}; do
        if [[ -S $temp/socket ]]; then return 0; fi
        if ! kill -0 "$peer" 2>/dev/null; then
            local rc=0; wait "$peer" || rc=$?; peer=''
            if [[ $rc == 77 ]]; then
                echo 'SKIP: this host blocks AF_UNIX creation; policy and PID tests passed'
                exit 0
            fi
            echo "Mock QMP server exited with $rc" >&2; exit 1
        fi
        sleep .02
    done
    echo 'QMP fixture did not listen in time' >&2; exit 1
}
start_peer
status=$("$root/build/uvp-qmp" "$temp/socket" "$peer" "$temp/peer")
[[ $status == inmigrate ]]
wait "$peer"; peer=''
start_peer
# Our executable and PID are valid, but the socket is served by a different PID.
if "$root/build/uvp-qmp" "$temp/socket" "$$" "$(readlink /proc/$$/exe)" 2>"$temp/error"; then exit 1; fi
grep -F 'QMP peer PID' "$temp/error" >/dev/null
echo 'PASS host validation, QMP event/reply matching and peer-PID verification'
