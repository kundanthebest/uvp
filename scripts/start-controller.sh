#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
state=${UVP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/uvp-orchestrator}
if [[ ! -x $root/build/uvp-controller ]]; then
    printf 'Build the Linux controller first: make -C "%s" controller\n' "$root" >&2
    exit 1
fi
exec "$root/build/uvp-controller" --root "$root" --data-dir "$state" "$@"
