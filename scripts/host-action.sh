#!/bin/bash -p
# SPDX-License-Identifier: GPL-2.0-only
# Execute the operation selected by a locally configured action profile.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C

usage() { printf '%s\n' "$*" >&2; exit 2; }
valid_nsid() {
    [[ $1 =~ ^[1-9][0-9]{0,9}$ ]] && (( 10#$1 <= 4294967294 ))
}

main() {
    (( EUID == 0 )) || usage 'Host actions require root'
    (( $# >= 2 )) || usage 'Usage: host-action.sh nvme-reset|namespace-delete|vf-flr TARGET [--nsid NSID]'
    local action=$1 target=$2 nsid nvme device method original observed
    shift 2
    case $action in
        nvme-reset|namespace-delete)
            [[ $target =~ ^/dev/nvme[0-9]+$ ]] || usage 'Expected controller /dev/nvmeN'
            if [[ $action == namespace-delete ]]; then
                [[ $# == 2 && $1 == --nsid ]] && valid_nsid "$2" || usage 'namespace-delete requires one explicit NSID in 1..4294967294'
                nsid=$2
            else
                (( $# == 0 )) || usage 'nvme-reset takes only the controller'
            fi
            [[ -c $target ]] || usage 'Controller character device missing'
            nvme=$(command -v nvme) || usage 'nvme-cli is not installed'
            if [[ $action == nvme-reset ]]; then
                printf 'Requesting NVMe reset on %s\n' "$target"
                exec "$nvme" reset "$target" </dev/null
            fi
            printf 'Requesting deletion of namespace %s on %s\n' "$nsid" "$target"
            exec "$nvme" delete-ns "$target" "--namespace-id=$nsid" </dev/null ;;
        vf-flr)
            [[ $# == 0 && $target =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]] || usage 'Expected full VF PCI BDF, e.g. 0000:83:00.1'
            device=/sys/bus/pci/devices/${target,,}
            [[ -L $device/physfn ]] || usage 'Target is not a VF'
            method=$device/reset_method
            [[ -r $method && -w $method ]] || usage 'VF reset_method is unavailable'
            original=$(cat -- "$method")
            [[ " $original " == *' flr '* ]] || usage 'FLR unavailable'
            # A subshell retains these local variables until EXIT restoration.
            (
                trap 'printf "%s\n" "$original" >"$method" || { echo "Could not restore VF reset_method" >&2; exit 1; }' EXIT
                trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
                printf 'flr\n' >"$method"
                observed=$(cat -- "$method")
                [[ $observed == flr ]] || usage 'Could not restrict reset_method to FLR'
                printf 'Requesting VF FLR on %s\n' "$target"
                printf '1\n' >"$device/reset"
            ) ;;
        *) usage 'Unrecognized host action' ;;
    esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
