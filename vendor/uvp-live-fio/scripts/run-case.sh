#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
source "$(dirname "$0")/common.sh"
tc=${1:?Usage: run-case.sh 1|2|3|4 config}
load_config "${2:?}"
case "$tc" in
    1) ctrl=$SOURCE_CONTROLLER; cntlid=$SOURCE_CNTLID; symbol=$SUSPEND_SYMBOL;;
    2) ctrl=$SOURCE_CONTROLLER; cntlid=$SOURCE_CNTLID; symbol=$GET_SYMBOL;;
    3) ctrl=$DEST_CONTROLLER; cntlid=$DEST_CNTLID; symbol=$SET_SYMBOL;;
    4) ctrl=$DEST_CONTROLLER; cntlid=$DEST_CNTLID; symbol=$RESUME_SYMBOL;;
    *) echo "Case must be 1,2,3,4" >&2; exit 2;;
esac
[[ $(id -u) == 0 ]] || { echo "Run this script with sudo" >&2; exit 2; }
[[ -f $RUN_DIR/prepared.status ]] || { echo "Prepare source guest / copy prepared.status before arming" >&2; exit 2; }
args=()
[[ ${DEBUG:-0} != 1 ]] || args+=(--debug)
# Reject stale READY instead of silently overwriting a previous run.
exec "$ROOT/bin/uvp-daemon" --case "$tc" \
    --controller "$ctrl" --cntlid "$cntlid" --phase-symbol "$symbol" \
    --bpf "$ROOT/bin/hooks.bpf.o" --timeout "$CHECKPOINT_TIMEOUT_SECONDS" \
    --action-timeout "$ACTION_TIMEOUT_SECONDS" --hold-ms "$HOLD_MS" \
    --ready-file "$RUN_DIR/ready" "${args[@]}" \
    -- "$ROOT/scripts/start-fio.sh" "$CONFIG"
