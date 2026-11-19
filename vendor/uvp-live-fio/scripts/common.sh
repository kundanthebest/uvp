#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Sourced by host scripts. Runtime is Bash + OpenSSH + ordinary Linux tools.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
load_config() {
    CONFIG=$(realpath -- "$1")
    # shellcheck disable=SC1090
    source "$CONFIG"
    [[ ${RUN_ID:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{3,63}$ && $RUN_ID != change-me ]] || {
        echo "Set a unique RUN_ID in config for this migration" >&2; exit 2;
    }
    : "${OUTPUT_DIR:?}" "${SSH_KEY:?}" "${SSH_KNOWN_HOSTS:?}" "${GUEST_USER:?}"
    [[ $GUEST_USER =~ ^[A-Za-z0-9_.-]+$ ]] || exit 2
    [[ -r $SSH_KEY && -r $SSH_KNOWN_HOSTS ]] || {
        echo "SSH key/known_hosts must exist; pre-verify BOTH SSH endpoints" >&2; exit 2;
    }
    RUN_DIR="$OUTPUT_DIR/$RUN_ID"
    mkdir -p -- "$RUN_DIR"
}
# A hard per-attempt timeout: ConnectTimeout alone cannot time out a paused VM
# which accepted TCP but never finishes the SSH handshake or remote command.
guest_ssh() {
    local side=$1 host port; shift
    case "$side" in
        source) host=$SOURCE_GUEST_HOST; port=$SOURCE_GUEST_PORT;;
        destination) host=$DEST_GUEST_HOST; port=$DEST_GUEST_PORT;;
        *) echo "Bad guest side: $side" >&2; return 2;;
    esac
    [[ $host =~ ^[A-Za-z0-9._:-]+$ && $port =~ ^[0-9]+$ ]] || return 2
    timeout --foreground --kill-after=2s 12s ssh \
        -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$SSH_KNOWN_HOSTS" \
        -o ConnectTimeout=3 -o ConnectionAttempts=1 \
        -o ServerAliveInterval=2 -o ServerAliveCountMax=2 \
        -i "$SSH_KEY" -p "$port" "$GUEST_USER@$host" "$@"
}
guest_exec() {
    local side=$1 quoted; shift
    printf -v quoted '%q ' "$@"
    guest_ssh "$side" "$quoted"
}
kv() { awk -F= -v key="$1" '$1==key {print substr($0,length(key)+2); exit}'; }
