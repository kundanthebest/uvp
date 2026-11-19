#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Run BEFORE migration, while the source guest is still runnable.
source "$(dirname "$0")/common.sh"
load_config "${1:?Usage: prepare-guest.sh config}"
[[ ${FIO_DIR:-} =~ ^/[A-Za-z0-9/_-]+$ && $FIO_DIR != / && $FIO_DIR != /dev* ]] || exit 2
for value in "$FIO_SIZE_MB" "$FIO_RUNTIME_SECONDS" "$FIO_IODEPTH"; do
    [[ $value =~ ^[0-9]+$ ]] && (( value > 0 )) || exit 2
done
[[ $FIO_ENGINE == libaio || $FIO_ENGINE == io_uring || $FIO_ENGINE == psync ]] || exit 2
# All interpolated arguments above are restricted tokens. Never run this against
# an incoming destination: its /run state must arrive from the source VM.
guest_exec source sudo -n bash -s -- "$RUN_ID" "$FIO_DIR" <<'REMOTE'
set -euo pipefail
id=$1; storage=$2; dir=/run/uvp-live-fio/$id
[[ ! -e $dir ]] || { echo "RUN_ID already exists; choose a fresh ID" >&2; exit 70; }
[[ $(findmnt -n -o FSTYPE -T /run) == tmpfs ]] || { echo "/run must be tmpfs" >&2; exit 70; }
mountpoint -q -- "$storage"
[[ $(findmnt -n -o MAJ:MIN -T "$storage") != $(findmnt -n -o MAJ:MIN -T /) ]]
/usr/bin/fio --version | grep -Eq '^fio-[0-9]'
umask 077
mkdir -p /run/uvp-live-fio
mkdir "$dir"
printf '%s\n' "$id" > "$dir/prepared"
echo "PREPARE: $(findmnt -n -o SOURCE,TARGET -T "$storage")"
REMOTE
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
cp "$ROOT/guest/guest-fio.sh" "$stage/"
printf 'FIO_DIR=%q\nFIO_SIZE_MB=%q\nFIO_RUNTIME_SECONDS=%q\nFIO_IODEPTH=%q\nFIO_ENGINE=%q\n' \
    "$FIO_DIR" "$FIO_SIZE_MB" "$FIO_RUNTIME_SECONDS" "$FIO_IODEPTH" "$FIO_ENGINE" > "$stage/settings"
tar -C "$stage" -cf - guest-fio.sh settings | \
    guest_exec source sudo -n tar -xf - -C "/run/uvp-live-fio/$RUN_ID"
guest_exec source sudo -n chmod 700 "/run/uvp-live-fio/$RUN_ID/guest-fio.sh"
guest_exec source sudo -n "/run/uvp-live-fio/$RUN_ID/guest-fio.sh" status "$RUN_ID" | tee "$RUN_DIR/prepared.status"
echo "PREPARED run=$RUN_ID. No fio has been started."
