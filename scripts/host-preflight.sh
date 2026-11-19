#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ $# == 0 ]]; then
    exec "$script_dir/host-bridge.sh" preflight <<<'{}'
fi
# Optional migration wrapper symbol check on the selected trigger host.
[[ $# == 1 && $1 =~ ^[a-zA-Z0-9_.$]+$ ]] || { echo 'Usage: host-preflight.sh [WRAPPER_SYMBOL]' >&2; exit 2; }
[[ $(uname -m) == x86_64 ]] || { echo 'Requires x86-64' >&2; exit 1; }
[[ -r /sys/kernel/btf/vmlinux ]] || { echo 'Kernel BTF missing' >&2; exit 1; }
[[ -x $script_dir/../vendor/uvp-live-fio/bin/uvp-daemon ]] || { echo 'Build the daemon first' >&2; exit 1; }
[[ -r $script_dir/../vendor/uvp-live-fio/bin/hooks.bpf.o ]] || { echo 'Build the BPF object first' >&2; exit 1; }
awk -v symbol="$1" '$3==symbol{found=1} END{exit !found}' /proc/kallsyms || { echo "Wrapper missing: $1" >&2; exit 1; }
printf 'Found wrapper %s and the local daemon and BPF objects\n' "$1"
