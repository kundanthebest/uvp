#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# A previous controller installation can keep its configured UVP helpers and run history.
set -euo pipefail
umask 077
export UVP_ROOT UVP_CONFIG UVP_STATE_DIR UVP_MODE=demo
UVP_ROOT=$(cd "$(dirname "$0")/.." && pwd)
dir=$(mktemp -d)
trap 'rm -rf -- "$dir"' EXIT
api=$UVP_ROOT/controller/api.sh
UVP_CONFIG=$dir/old.json
UVP_STATE_DIR=$dir/state
mkdir "$UVP_STATE_DIR"
jq '.hosts.source.bridge="/opt/uvp/scripts/host-bridge.py" |
    .actions["source-custom"].argv=["/usr/bin/python3","/opt/uvp/scripts/host-action.py","nvme-reset","/dev/nvme5"] |
    .jobs.migrate.argv=["/usr/bin/sudo","-n","--","/usr/bin/python3","/opt/uvp/scripts/host-bridge.py","migrate"] |
    .jobs.collect.argv=["/usr/bin/printf","%s","/opt/uvp/scripts/host-action.py"]' "$UVP_ROOT/config/demo.json" > "$UVP_CONFIG"
if command -v sqlite3 >/dev/null; then
    db=$UVP_STATE_DIR/uvp.sqlite3
    sqlite3 -batch -bail "$db" <<'SQL'
CREATE TABLE runs(id TEXT PRIMARY KEY, body TEXT);
CREATE TABLE events(seq INTEGER PRIMARY KEY, run_id TEXT, time REAL, kind TEXT, message TEXT);
INSERT INTO runs VALUES('abcdef012345','{"id":"abcdef012345","status":"PAUSED","migration_script_status":"RUNNING"}');
INSERT INTO events VALUES(8,'abcdef012345',1.0,'daemon','completed command');
SQL
    before=$(sha256sum "$db")
elif [[ -n ${GITHUB_ACTIONS:-} ]]; then
    echo 'FAIL: CI requires sqlite3 for the history migration test' >&2; exit 1
fi
"$api" init
jq -e '.config.hosts.source.bridge=="/opt/uvp/scripts/host-bridge.sh" and
       .config.actions["source-custom"].argv==["/opt/uvp/scripts/host-action.sh","nvme-reset","/dev/nvme5"] and
       .config.jobs.migrate.argv==["/usr/bin/sudo","-n","--","/opt/uvp/scripts/host-bridge.sh","migrate"] and
       .config.jobs.collect.argv==["/usr/bin/printf","%s","/opt/uvp/scripts/host-action.py"]' "$UVP_STATE_DIR/state.json" >/dev/null
echo 'PASS: upgrades the configured helper paths and preserves unrelated operator arguments'
if [[ -n ${db:-} ]]; then
    for attempt in 1 2; do
        "$api" GET /api/state | tail -n +2 |
            jq -e '.run==null and .history[0].status=="INTERRUPTED" and .history[0].migration_script_status=="INTERRUPTED"' >/dev/null
        "$api" GET /api/runs/abcdef012345/export | tail -n +2 |
            jq -e '.run.id=="abcdef012345" and .events==[{seq:8,time:1,kind:"daemon",message:"completed command"}]' >/dev/null
        [[ $attempt != 1 ]] || "$api" init
    done
    [[ $before == "$(sha256sum "$db")" ]]
    echo 'PASS: imports previous history once, preserves the original database and exports interrupted runs'
else
    echo 'SKIP: sqlite3 CLI unavailable for previous-release database fixture'
fi
