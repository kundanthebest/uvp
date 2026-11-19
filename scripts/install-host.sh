#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
role=''
dependencies=false
while (($#)); do
    case $1 in
        --role) role=${2:?Expected source or destination}; shift 2 ;;
        --install-deps) dependencies=true; shift ;;
        *) echo 'Usage: sudo scripts/install-host.sh --role source|destination [--install-deps]' >&2; exit 2 ;;
    esac
done
[[ $role == source || $role == destination ]] || { echo 'Select --role source or --role destination' >&2; exit 2; }
((EUID == 0)) || { echo 'Run with sudo on the intended Linux host' >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo 'Hardware mode requires x86-64 Linux' >&2; exit 1; }
if "$dependencies"; then
    command -v apt-get >/dev/null || { echo 'Install the dependencies in docs/DEPLOYMENT.md for this distribution' >&2; exit 1; }
    apt-get update
    apt-get install -y build-essential clang llvm pkg-config libbpf-dev libelf-dev zlib1g-dev openssh-client nvme-cli jq socat util-linux coreutils
fi
src=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
dst=/opt/uvp-orchestrator
[[ ! -L $dst ]] || { echo "Refusing symlink at $dst" >&2; exit 1; }
install -d -o root -g root -m 0755 "$dst" /etc/uvp
install -d -o root -g root -m 0750 /var/log/uvp /run/uvp-hmlm
# Only install files in the distributed manifest. Local keys, configuration
# and build products in the checkout never enter the privileged installation.
cd "$src"
sha256sum --check --quiet SHA256SUMS
install_entry() {
    local rel=$1 mode=0644 parent component current
    [[ $rel =~ ^[.a-zA-Z0-9_/-]+$ && $rel != /* && /$rel/ != */../* ]] || return 1
    [[ -f $src/$rel && ! -L $src/$rel ]] || return 1
    current=$dst
    IFS=/ read -ra parents <<< "${rel%/*}"
    if [[ $rel == */* ]]; then
        for component in "${parents[@]}"; do
            current=$current/$component
            [[ ! -L $current ]] || return 1
            install -d -o root -g root -m 0755 "$current"
        done
    fi
    [[ ! -L $dst/$rel ]] || return 1
    [[ $rel != *.sh ]] || mode=0755
    if [[ $src != "$dst" ]]; then
        install -o root -g root -m "$mode" -- "$src/$rel" "$dst/$rel"
    else
        chown root:root -- "$dst/$rel"
        chmod "$mode" -- "$dst/$rel"
    fi
}
while read -r hash rel; do install_entry "$rel"; done < SHA256SUMS
install_entry SHA256SUMS
make -C "$dst" build CLANG=/usr/bin/clang
if [[ ! -e /etc/uvp/host.json ]]; then
    install -o root -g root -m 0600 "$dst/config/host-${role}.example.json" /etc/uvp/host.json
fi
echo "Installed host tools at $dst. Configure /etc/uvp/host.json, then run sudo $dst/scripts/host-preflight.sh."
