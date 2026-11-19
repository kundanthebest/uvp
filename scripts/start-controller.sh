#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
UVP_STATE_PATH="${UVP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/uvp-orchestrator}"
exec python3 -m uvp_server.server --data-dir "$UVP_STATE_PATH" "$@"
