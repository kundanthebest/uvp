#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Optional: start on SOURCE immediately before your existing migration command.
# First arm run-case.sh on the trigger host and confirm READY.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
config=${1:?Usage: migrate-with-fio.sh config -- ./migrate.sh [args...]}
[[ ${2:-} == -- && $# -ge 3 ]] || exit 2
shift 2
"$root/scripts/prestart-fio.sh" "$config"
exec "$@"
