#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
source "$(dirname "$0")/common.sh"
load_config "${1:?Usage: collect-results.sh config [source|destination]}"
side=${2:-destination}
guest_exec "$side" sudo -n "/run/uvp-live-fio/$RUN_ID/guest-fio.sh" status "$RUN_ID" | tee "$RUN_DIR/final.status"
guest_exec "$side" sudo -n tar -czf - -C /run/uvp-live-fio "$RUN_ID" > "$RUN_DIR/guest-results.tar.gz"
echo "Collected $RUN_DIR/guest-results.tar.gz (wait for DONE/FIO_EXIT=0 for final result)"
