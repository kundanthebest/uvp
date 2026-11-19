#!/usr/bin/env bash
# Read-only checks. Run on the selected trigger host, before hardware arming.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
symbol=${1:-nvmevf_cmd_suspend_device}
[[ $symbol =~ ^[a-zA-Z0-9_.$]+$ ]] || exit 2
[[ $(uname -m) == x86_64 ]] || { echo 'Requires x86-64'; exit 1; }
[[ -r /sys/kernel/btf/vmlinux ]] || { echo 'Kernel BTF missing'; exit 1; }
[[ -x $root/vendor/uvp-live-fio/bin/uvp-daemon ]] || { echo 'Build daemon first'; exit 1; }
[[ -r $root/vendor/uvp-live-fio/bin/hooks.bpf.o ]] || { echo 'Build BPF object first'; exit 1; }
awk -v s="$symbol" '$3==s {found=1} END {exit !found}' /proc/kallsyms || { echo "Wrapper missing: $symbol"; exit 1; }
echo 'Read-only prerequisites found. Actual BPF load/attach happens on Arm.'
