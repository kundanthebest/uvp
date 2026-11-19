#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Root inside the guest. Run-specific state is in tmpfs, and migrates with RAM.
# No host markers are injected into guest RAM/storage while migration is paused.
set -euo pipefail
umask 077
base=${UVP_GUEST_BASE:-/run/uvp-live-fio} # override only for local mock tests
cmd=${1:?}; id=${2:?}
[[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]{3,63}$ ]] || exit 2
dir="$base/$id"
[[ -d $dir && ! -L $dir && -f $dir/prepared ]] || { echo "NOT_PREPARED"; exit 70; }
[[ $(cat "$dir/prepared") == "$id" ]] || exit 70
# Only a root-created, trusted settings file is sourced.
# shellcheck disable=SC1090
source "$dir/settings"
start_ticks() {
    local text rest
    text=$(cat "/proc/$1/stat") || return 1
    rest=${text##*) }
    awk '{print $20}' <<< "$rest" # field 22 in full /proc/PID/stat
}
status() {
    local pid ticks state=STARTING
    [[ -d $dir/launch.lock ]] || state=PREPARED
    if [[ -f $dir/exit-code ]]; then
        state=DONE
    elif [[ -f $dir/fio.pid && -f $dir/start-ticks ]]; then
        pid=$(cat "$dir/fio.pid"); ticks=$(cat "$dir/start-ticks")
        if [[ -r /proc/$pid/stat && $(start_ticks "$pid") == "$ticks" ]] &&
           [[ $(awk '/^State:/{print $2}' "/proc/$pid/status") != Z ]]; then
            state=RUNNING
        else state=LOST; fi
    fi
    printf 'STATE=%s\nRUN_ID=%s\nBOOT_ID=%s\n' "$state" "$id" "$(cat /proc/sys/kernel/random/boot_id)"
    [[ ! -f $dir/fio.pid ]] || printf 'FIO_PID=%s\n' "$(cat "$dir/fio.pid")"
    [[ ! -f $dir/start-ticks ]] || printf 'START_TICKS=%s\n' "$(cat "$dir/start-ticks")"
    [[ ! -f $dir/origin ]] || printf 'ORIGIN=%s\n' "$(cat "$dir/origin")"
    [[ ! -f $dir/started-at ]] || printf 'STARTED_AT=%s\n' "$(cat "$dir/started-at")"
    [[ ! -f $dir/exit-code ]] || printf 'FIO_EXIT=%s\n' "$(cat "$dir/exit-code")"
    if [[ $state == RUNNING ]]; then
        awk '/^read_bytes:/{print "READ_BYTES=" $2} /^write_bytes:/{print "WRITE_BYTES=" $2}' "/proc/$pid/io"
    fi
}
case "$cmd" in
start)
    origin=${3:-event}
    expected_boot=${4:-}
    if [[ -n $expected_boot && $(cat /proc/sys/kernel/random/boot_id) != "$expected_boot" ]]; then
        echo "WRONG_GUEST_BOOT_ID"; exit 70
    fi
    [[ $origin =~ ^[A-Za-z0-9._-]+$ ]] || exit 2
    if mkdir "$dir/launch.lock" 2>/dev/null; then
        # Atomic once-per-run guard, including lost SSH acknowledgements.
        printf '%s\n' "$origin" > "$dir/origin"
        nohup bash "$dir/guest-fio.sh" _run "$id" >"$dir/runner.log" 2>&1 </dev/null &
        echo "$!" > "$dir/runner.pid"
    fi
    status
    ;;
status) status;;
_run)
    # The launcher is the only writer; cleanup always reports fio's actual rc.
    rc=125
    trap 'printf "%s\n" "$rc" > "$dir/exit-code"' EXIT
    fio_binary=${FIO_BINARY:-/usr/bin/fio}
    "$fio_binary" --version | grep -Eq '^fio-[0-9]'
    testfile="$FIO_DIR/uvp-$id.dat"
    [[ ! -e $testfile && ! -L $testfile ]] || { echo "Refusing existing test file"; exit 1; }
    [[ $FIO_DIR != /dev* && $FIO_DIR != / && ! -L $FIO_DIR ]] || exit 1
    # Test-only mock bypass is NEVER written by the production prepare script.
    if [[ ${UVP_MOCK_ONLY:-0} != 1 ]]; then
        mountpoint -q -- "$FIO_DIR"
        [[ $(findmnt -n -o MAJ:MIN -T "$FIO_DIR") != $(findmnt -n -o MAJ:MIN -T /) ]]
    fi
    "$fio_binary" --name=uvp --filename="$testfile" \
        --rw=randrw --rwmixread=30 --bs=4k --direct=1 \
        --ioengine="$FIO_ENGINE" --iodepth="$FIO_IODEPTH" --numjobs=1 --thread=1 \
        --size="${FIO_SIZE_MB}M" --time_based=1 --runtime="$FIO_RUNTIME_SECONDS" \
        --group_reporting=1 --output-format=json --output="$dir/fio.json" \
        --write_bw_log="$dir/bw" --write_iops_log="$dir/iops" --log_avg_msec=1000 &
    pid=$!
    printf '%s\n' "$pid" > "$dir/fio.pid"
    if [[ -r /proc/$pid/stat ]]; then start_ticks "$pid" > "$dir/start-ticks"; fi
    date -Ins > "$dir/started-at"
    printf 'FIO_EXEC pid=%s guest_time=%s\n' "$pid" "$(cat "$dir/started-at")"
    set +e
    wait "$pid"; rc=$?
    set -e
    echo "FIO_DONE rc=$rc"
    exit "$rc"
    ;;
*) echo "Use: start|status RUN_ID" >&2; exit 2;;
esac
