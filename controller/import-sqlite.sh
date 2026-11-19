#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Called once under the state lock. The previous database is opened read-only.
# A failed import is retryable: staging is private and state.json is created last.
import_legacy() {
    local db=$UVP_STATE_DIR/uvp.sqlite3 staging=$1 id record
    [[ -f $db ]] || { printf '%s\n' '{"seq":0,"events":[],"history":[]}'; return; }
    if ! command -v sqlite3 >/dev/null; then
        echo 'Install the sqlite3 CLI to import the existing UVP run history.' >&2
        return 1
    fi
    mkdir -p -- "$staging/runs"
    sqlite3 -batch -bail -readonly "$db" 'SELECT body FROM runs ORDER BY rowid DESC;' >"$staging/legacy-runs" || return 1
    while IFS= read -r record; do
        id=$(jq -er '.id | select(type=="string" and test("^[a-f0-9]{12}\\z"))' <<<"$record") || return 1
        jq -ce -L "$UVP_ROOT/controller" 'include "validate"; if (.status|active) then
          . + {status:"INTERRUPTED",hold_deadline:null,detail:"Controller restarted; check actual VM state."}
          else . end | if .migration_script_status=="RUNNING" then .migration_script_status="INTERRUPTED" else . end' \
          <<<"$record" >"$staging/runs/$id.json" || return 1
        cat "$staging/runs/$id.json" >> "$staging/history"
    done <"$staging/legacy-runs"
    touch "$staging/history"
    sqlite3 -batch -bail -readonly "$db" "SELECT json_object('seq',seq,'run_id',run_id,'time',time,'kind',kind,'message',message) FROM events ORDER BY seq;" \
        >"$staging/events" || return 1
    # All event objects are produced by SQLite JSON1. Restrict file names before
    # splitting the stream, including journals for runs absent from the old DB.
    jq -r 'if (.run_id=="system" or (.run_id|type=="string" and test("^[0-9a-f]{12}\\z")))
        then .run_id+" "+tojson else error("Invalid legacy run ID") end' "$staging/events" >"$staging/event-map" || return 1
    while IFS=' ' read -r id record; do printf '%s\n' "$record" >>"$staging/runs/$id.events" || return 1; done <"$staging/event-map"
    head -n 30 "$staging/history" >"$staging/recent"
    tail -n 250 "$staging/events" >"$staging/recent-events"
    jq -cn --slurpfile history "$staging/recent" --slurpfile events "$staging/recent-events" \
        '{seq:($events[-1].seq // 0),events:$events,history:$history}'
}
