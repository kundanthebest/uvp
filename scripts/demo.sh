#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
make -C "$root" controller
exec "$root/scripts/start-controller.sh" --config "$root/config/demo.json" "$@"
