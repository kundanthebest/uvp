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
"${UVP_DAEMON:-$root/bin/uvp-daemon}" --selftest --case 1 --hold-ms 5000 -- /bin/true > "$tmp/log" 2>&1 &
daemon=$!
for _ in {1..300}; do grep -q '^STOP_CONFIRMED' "$tmp/log" && break; sleep .01; done
grep -q '^STOP_CONFIRMED' "$tmp/log"
target=$(sed -n 's/^READY pid=\([0-9]*\).*/\1/p' "$tmp/log")
kill -KILL "$daemon"
wait "$daemon" 2>/dev/null || true
daemon=
for _ in {1..200}; do
    [[ $(awk '/^State:/{print $2}' "/proc/$target/status") != T ]] && break
    sleep .02
done
[[ $(awk '/^State:/{print $2}' "/proc/$target/status") != T ]]
grep -q WATCHDOG "$tmp/log"
echo 'PASS: daemon SIGKILL during synthetic hold -> independent watchdog releases target'
