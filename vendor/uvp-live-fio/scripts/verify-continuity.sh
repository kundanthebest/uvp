#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
source "$(dirname "$0")/common.sh"
load_config "${1:?Usage: verify-continuity.sh config}"
baseline="$RUN_DIR/pre-migration.status"
[[ -f $baseline ]] || { echo "No pre-migration fio identity: event-launch is not continuity" >&2; exit 1; }
first=$(guest_exec destination sudo -n "/run/uvp-live-fio/$RUN_ID/guest-fio.sh" status "$RUN_ID")
sleep 3
second=$(guest_exec destination sudo -n "/run/uvp-live-fio/$RUN_ID/guest-fio.sh" status "$RUN_ID")
for key in RUN_ID BOOT_ID FIO_PID START_TICKS ORIGIN; do
    expected=$(kv "$key" < "$baseline")
    [[ -n $expected && $(kv "$key" <<< "$first") == "$expected" &&
        $(kv "$key" <<< "$second") == "$expected" ]] || {
        echo "FAIL: $key changed/missing; not the same fio instance" >&2; exit 1;
    }
done
[[ $(kv STATE <<< "$first") == RUNNING && $(kv STATE <<< "$second") == RUNNING ]] || {
    echo "fio not running on destination; increase runtime or inspect failure" >&2; exit 1;
}
r1=$(kv READ_BYTES <<< "$first"); w1=$(kv WRITE_BYTES <<< "$first")
r2=$(kv READ_BYTES <<< "$second"); w2=$(kv WRITE_BYTES <<< "$second")
for n in "$r1" "$w1" "$r2" "$w2"; do [[ $n =~ ^[0-9]+$ ]] || exit 1; done
(( r2 > r1 || w2 > w1 )) || { echo "No observed I/O-byte progress after migration" >&2; exit 1; }
printf '%s\n' "$first" > "$RUN_DIR/dest-first.status"
printf '%s\n' "$second" > "$RUN_DIR/dest-second.status"
echo "CONTINUITY_OBSERVED: same boot/PID/start ticks; I/O accounting advanced on destination."
echo "Still inspect final fio exit/JSON and migration result; this is not CRC data verification."
