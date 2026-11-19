#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: sudo ./scripts/migrate.sh DESTINATION_IPV4' >&2; exit 2; }
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
/usr/bin/python3 - "$1" <<'PY' | /usr/bin/python3 "$SCRIPT_DIR/host-bridge.py" migrate
import ipaddress, json, sys
address = ipaddress.ip_address(sys.argv[1])
if address.version != 4 or address.is_multicast or address.is_unspecified:
    raise SystemExit('Expected unicast destination IPv4 address')
print(json.dumps({'role':'source','destination_ip':str(address)}))
PY
