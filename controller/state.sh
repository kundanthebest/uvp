#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Shared by the API handler and controller workers. All mutations require fd 9
# to hold the state lock. Never carry that lock into long-running child commands.
: "${UVP_ROOT:?}" "${UVP_STATE_DIR:?}"
STATE="$UVP_STATE_DIR/state.json"
export STATE

lock_state() {
    exec 9>"$UVP_STATE_DIR/state.lock" || return 1
    if ! flock -x -w 10 9; then exec 9>&-; return 1; fi
    if [[ -n ${UVP_SESSION:-} ]] && ! jq -e --arg session "$UVP_SESSION" '.session == $session' "$STATE" >/dev/null; then
        unlock_state
        return 1
    fi
}
unlock_state() { exec 9>&-; }

# Last argument is the jq expression. Earlier arguments are jq options.
state_update() {
    local expr="${!#}" tmp
    local -a options=("${@:1:$#-1}")
    tmp=$(mktemp "$UVP_STATE_DIR/.state.XXXXXXXX") || return 1
    if ! jq -ec -L "$UVP_ROOT/controller" "${options[@]}" \
        "include \"validate\"; ($expr) | if .run then .history = ([.run] + (.run.id as \$id | [.history[] | select(.id != \$id)]))[:30] else . end" \
        "$STATE" > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    mv -fT -- "$tmp" "$STATE"
}

event() {
    local kind=$1 msg=${2:0:8192} rid=${3:-} record
    if [[ ! $rid ]]; then rid=$(jq -r '.run.id // "system"' "$STATE") || return 1; fi
    [[ $rid == system || $rid =~ ^[0-9a-f]{12}$ ]] || return 1
    record=$(jq -c --arg kind "$kind" --arg msg "$msg" --arg id "$rid" \
        '{seq:(.seq+1),run_id:$id,time:now,kind:$kind,message:$msg}' "$STATE") || return 1
    # Keep the complete per-run journal on disk; limit the dashboard to its last 250 events.
    printf '%s\n' "$record" >>"$UVP_STATE_DIR/runs/$rid.events" || return 1
    state_update --argjson record "$record" '.seq = $record.seq | .events = ((.events + [$record])[-250:])'
}

archive_run() {
    local record rid tmp
    record=$(jq -c '.run // empty' "$STATE") || return 1
    [[ $record ]] || return 0
    rid=$(jq -er '.id | select(type=="string" and test("^[0-9a-f]{12}\\z"))' <<<"$record") || return 1
    tmp=$(mktemp "$UVP_STATE_DIR/runs/.record.XXXXXXXX") || return 1
    if ! printf '%s\n' "$record" >"$tmp"; then rm -f -- "$tmp"; return 1; fi
    mv -fT -- "$tmp" "$UVP_STATE_DIR/runs/$rid.json"
}

# Field 22 (starttime) is stable across exec. Strip pid/comm before splitting
# because a process name can contain whitespace and parentheses.
start_ticks() {
    local line rest
    [[ $1 =~ ^[1-9][0-9]*$ ]] || return 1
    IFS= read -r line 2>/dev/null <"/proc/$1/stat" || return 1
    rest=${line##*) }
    local -a fields
    read -ra fields <<<"$rest"
    [[ ${fields[0]:-Z} != Z && ${fields[19]:-} =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${fields[19]}"
}

# .pid records live in a private directory and are accepted only for this session.
worker_identity() {
    local rec=$1 current
    read -r worker_session worker_pid worker_ticks <"$rec" || return 1
    [[ $worker_session == "$UVP_SESSION" && $worker_pid =~ ^[1-9][0-9]*$ ]] || return 1
    current=$(start_ticks "$worker_pid") && [[ $current == "$worker_ticks" ]]
}

interrupt_stale() {
    state_update 'if .run and (.run.status|active) then
      .run += {status:"INTERRUPTED",hold_deadline:null,ended_at:now,detail:"Coordinator restarted; check watchdog and actual VM state."}
      else . end | if .run.migration_script_status=="RUNNING" then .run.migration_script_status="INTERRUPTED" else . end'
}
