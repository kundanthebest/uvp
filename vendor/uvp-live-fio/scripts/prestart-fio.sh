#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Optional TRUE continuity experiment: launch BEFORE migration, save identity.
source "$(dirname "$0")/common.sh"
load_config "${1:?Usage: prestart-fio.sh config}"
"$ROOT/scripts/start-fio.sh" "$CONFIG" source pre-migration
out=$(guest_exec source sudo -n "/run/uvp-live-fio/$RUN_ID/guest-fio.sh" status "$RUN_ID")
[[ $(kv STATE <<< "$out") == RUNNING && $(kv ORIGIN <<< "$out") == pre-migration ]] || {
    echo "Need a live fio started by this prestart run" >&2; exit 1;
}
printf '%s\n' "$out" | tee "$RUN_DIR/pre-migration.status"
echo "Start migration now using your existing migrate.sh; daemon action is idempotent."
