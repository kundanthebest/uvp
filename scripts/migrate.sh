#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: sudo ./scripts/migrate.sh DESTINATION_IPV4' >&2; exit 2; }
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
jq -nc --arg ip "$1" '{role:"source",destination_ip:$ip}' | "$SCRIPT_DIR/host-bridge.sh" migrate
