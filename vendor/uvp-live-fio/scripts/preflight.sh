#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
[[ $(uname -m) == x86_64 ]] || { echo 'Native x86-64 only'; exit 1; }
[[ -r /sys/kernel/btf/vmlinux ]] || { echo 'Missing /sys/kernel/btf/vmlinux'; exit 1; }
t=/sys/kernel/tracing
[[ -r $t/available_filter_functions ]] || t=/sys/kernel/debug/tracing
for sym in nvme_init_request "${1:-nvmevf_cmd_suspend_device}"; do
    if ! grep -Eq "^${sym}([[:space:]]|$)" "$t/available_filter_functions"; then
        echo "Missing/inlined function: $sym. Verify exact wrapper (including .isra suffix)."; exit 1
    fi
done
for p in raw_syscalls/sys_enter raw_syscalls/sys_exit nvme/nvme_complete_rq; do
    [[ -r $t/events/$p/format ]] || { echo "Missing tracepoint: $p"; exit 1; }
done
echo "Preflight names/BTF found; verifier/load compatibility is checked by daemon."
echo "NVMe module BTF may also be needed at /sys/kernel/btf/nvme_core."
