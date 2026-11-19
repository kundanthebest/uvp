#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Internal dispatcher, invoked by the loopback C HTTP service.
set -euo pipefail
umask 077
: "${UVP_ROOT:?}" "${UVP_CONFIG:?}" "${UVP_STATE_DIR:?}" "${UVP_MODE:?}"
source "$UVP_ROOT/controller/state.sh"

die() { printf '%s\n' "$1"; jq -cn --arg message "$2" '{error:$message}'; exit 0; }
reply() { printf '%s\n%s\n' "$1" "$2"; exit 0; }
uuid() { tr -d '-' </proc/sys/kernel/random/uuid; }
new_id() {
    local s
    while :; do
        s=$(uuid); s=${s:0:12}
        if [[ ! -e $UVP_STATE_DIR/workers/$s.pid && ! -e $UVP_STATE_DIR/runs/$s.json &&
              ! -e $UVP_STATE_DIR/control-$s ]]; then printf '%s\n' "$s"; return; fi
    done
}
# Catch jq errors as data. Only application-defined 400/409 messages are exposed.
validate() {
    local filter=$1 error code packed
    shift
    packed=$(jq -ec -L "$UVP_ROOT/controller" "$@" "include \"validate\"; try {value:($filter)} catch {error:.}" "$STATE") || die 500 'Cannot read controller state'
    if jq -e 'has("error")' <<<"$packed" >/dev/null; then
        error=$(jq -r .error <<<"$packed")
        code=${error%% *}
        case "$code" in 400|409) die "$code" "${error#* }";; *) die 400 'Invalid request fields';; esac
    fi
    VALUE=$(jq -c .value <<<"$packed")
}

initialize() (
    local cfg record session="${UVP_SESSION:-}" staging
    [[ $UVP_MODE == demo || $UVP_MODE == hardware ]] || { echo 'Invalid mode' >&2; return 1; }
    [[ $session ]] || session=$(uuid)
    mkdir -p -- "$UVP_STATE_DIR"/{runs,workers}
    chmod 700 -- "$UVP_STATE_DIR" "$UVP_STATE_DIR/runs" "$UVP_STATE_DIR/workers"
    cfg=$(jq -ces -L "$UVP_ROOT/controller" --arg mode "$UVP_MODE" 'include "legacy-config"; select(length==1) | .[0] |
      select(type=="object" and (.hosts.source|type)=="object" and (.hosts.destination|type)=="object"
        and ((.actions // {})|type)=="object" and ((.jobs // {})|type)=="object"
        and ($mode!="hardware" or .demo!=true)) | adapt_legacy' "$UVP_CONFIG") || { echo 'Invalid controller configuration or mode' >&2; return 1; }
    exec 9>"$UVP_STATE_DIR/state.lock"; flock -x -w 10 9
    staging=$(mktemp -d "$UVP_STATE_DIR/.init.XXXXXXXX")
    trap 'rm -rf -- "$staging"' EXIT
    if [[ -e $STATE ]]; then
        # Fence late publishers with the next session generation before serving.
        # Signal any still-live transport from this controller's previous generation.
        UVP_SESSION=$(jq -er '.session' "$STATE")
        for record in "$UVP_STATE_DIR"/workers/*.pid; do
            [[ -f $record ]] || continue
            if worker_identity "$record"; then kill -TERM "$worker_pid" 2>/dev/null || :; fi
            rm -f -- "$record"
        done
        interrupt_stale
        archive_run
        jq -ce '{history,events,seq}' "$STATE" >"$staging/marks"
    else
        source "$UVP_ROOT/controller/import-sqlite.sh"
        import_legacy "$staging" >"$staging/marks" || return 1
        if [[ -d $staging/runs ]]; then cp -a "$staging/runs/." "$UVP_STATE_DIR/runs/" || return 1; fi
    fi
    jq -ces --arg session "$session" --arg mode "$UVP_MODE" --argjson cfg "$cfg" '
        .[0] + {session:$session, mode:$mode, config:$cfg, run:null, job:null, closing:false,
          setup:{status:"IDLE",detail:"Prepare destination, then source"}}' "$staging/marks" >"$staging/state"
    mv -fT -- "$staging/state" "$STATE"
    rm -rf -- "$staging"
    trap - EXIT
    unlock_state
)

# Launch in its own session, preserving no lock or HTTP streams. The PID plus
# /proc start time prevents a shutdown from signalling a reused PID.
launch_worker() {
    local verb=$1 id=$2 pid ticks reg="$UVP_STATE_DIR/workers/$2.pid"
    [[ -x $UVP_ROOT/controller/worker.sh ]] || return 1
    setsid "$UVP_ROOT/controller/worker.sh" "$verb" "$id" \
        </dev/null >/dev/null 2>"$UVP_STATE_DIR/workers/$id.log" 9>&- &
    pid=$!
    ticks=$(start_ticks "$pid") || return 1
    printf '%s %s %s\n' "$UVP_SESSION" "$pid" "$ticks" >"$reg"
}

# Detect unexpected worker termination as well as ordinary lifecycle callbacks.
check_workers() {
    local id item
    while IFS=$'\t' read -r item id; do
        [[ $id =~ ^[a-f0-9]{12}$ ]] || continue
        if [[ ! -f $UVP_STATE_DIR/workers/$id.pid ]] || ! worker_identity "$UVP_STATE_DIR/workers/$id.pid"; then
            case "$item" in
                run) state_update '.run += {status:"FAILED",ended_at:now,hold_deadline:null,detail:"Daemon monitor exited unexpectedly; inspect the watchdog and host state"}';;
                job) state_update '.job += {status:"FAILED",detail:"Job monitor exited unexpectedly"} |
                    if .job.kind == "migration" and .run.id == .job.run_id then .run.migration_script_status="FAILED" else . end';;
                setup) state_update '.setup += {status:"FAILED",detail:"Host preparation monitor exited unexpectedly"}';;
            esac
            event error "$item worker exited unexpectedly; inspect the host"
        fi
    done < <(jq -r -L "$UVP_ROOT/controller" 'include "validate"; [
      (if .run.status|active then ["run",.run.id] else empty end),
      (if .job.status=="RUNNING" then ["job",.job.id] else empty end),
      (if .setup.status=="PREPARING" or .setup.status=="CHECKING" then ["setup",.setup.id] else empty end)
    ][] | @tsv' "$STATE")
}

stop_workers() {
    local record id
    state_update '.closing=true'
    id=$(jq -r -L "$UVP_ROOT/controller" 'include "validate"; .run|select(.status|active)|.id' "$STATE")
    [[ ! $id ]] || printf 'cancel\n' >>"$UVP_STATE_DIR/control-$id"
    for record in "$UVP_STATE_DIR"/workers/*.pid; do
        [[ -f $record ]] || continue
        if worker_identity "$record"; then kill -TERM "$worker_pid" 2>/dev/null || :; fi
    done
    unlock_state
}

if [[ ${1:-} == init ]]; then initialize; exit; fi
lock_state || { [[ ${1:-} != shutdown ]] || exit 1; die 503 'Controller state is unavailable or belongs to another session'; }
UVP_SESSION=$(jq -er '.session' "$STATE"); export UVP_SESSION
if [[ ${1:-} == shutdown ]]; then stop_workers; exit; fi
method=${1:-}; path=${2:-}
body='{}'
if [[ $method == POST ]]; then
    # Reject NULs even as JSON escapes before any input can enter a shell argument.
    body=$(jq -ces 'select(length == 1) | .[0] | select(type=="object" and all(..|strings; explode|all(.!=0)))') || die 400 'Expected exactly one valid JSON object'
fi
check_workers

case "$method $path" in
    'GET /api/info') reply 200 "$(jq -c '{mode}' "$STATE")" ;;
    'GET /api/config') validate public_config; reply 200 "$VALUE" ;;
    'GET /api/state') reply 200 "$(jq -c '{mode,run,job,setup,events,history}' "$STATE")" ;;
    'POST /api/hosts')
        validate ready_for_change
        source_ip=$(jq -er '.source.address | select(type == "string")' <<<"$body") || die 400 'Enter a literal source IP'
        dest_ip=$(jq -er '.destination.address | select(type == "string")' <<<"$body") || die 400 'Enter a literal destination IP'
        source_ip=$("$UVP_ROOT/build/uvp-ip" "$source_ip") || die 400 'Enter a literal source IPv4 or IPv6 address'
        dest_ip=$("$UVP_ROOT/build/uvp-ip" "$dest_ip") || die 400 'Enter a literal destination IPv4 or IPv6 address'
        validate 'updated_hosts($req;$src;$dst)' --argjson req "$body" --arg src "$source_ip" --arg dst "$dest_ip"
        state_update --argjson hosts "$VALUE" '.config.hosts=$hosts | .setup={status:"IDLE",detail:"Host settings changed; prepare hosts again"}'
        event config 'Updated source and destination connections for this controller session'
        validate public_config; reply 200 "$VALUE" ;;
    'POST /api/prepare'|'POST /api/preflight')
        validate ready_for_change
        verb=${path##*/}; id=$(new_id); status=PREPARING; [[ $verb == prepare ]] || status=CHECKING
        state_update --arg id "$id" --arg status "$status" '.setup={id:$id,status:$status,detail:"Checking destination first",hosts:{}}'
        if ! launch_worker "$verb" "$id"; then
            state_update '.setup += {status:"FAILED",detail:"Cannot start host preparation worker"}'
            die 500 'Cannot start host preparation worker'
        fi
        reply 202 "$(jq -c .setup "$STATE")" ;;
    'POST /api/runs')
        id=$(new_id)
        validate 'new_run($req;$id)' --argjson req "$body" --arg id "$id"
        archive_run
        : >"$UVP_STATE_DIR/control-$id"
        state_update --argjson run "$VALUE" '.run=$run'
        event run "Starting $UVP_MODE checkpoint run"
        if ! launch_worker run "$id"; then
            state_update '.run += {status:"FAILED",detail:"Cannot start daemon monitor"}'
            die 500 'Cannot start daemon monitor'
        fi
        reply 201 "$VALUE" ;;
    'POST /api/jobs')
        id=$(new_id)
        validate 'new_job($req;$id)' --argjson req "$body" --arg id "$id"
        job=$VALUE
        if [[ $(jq -r .kind <<<"$job") == migration ]]; then
            if jq -e '.config.jobs[ $job.key ].bridge_verb=="migrate"' --argjson job "$job" "$STATE" >/dev/null; then
                "$UVP_ROOT/build/uvp-ip" "$(jq -r '.config.hosts.destination.address' "$STATE")" >/dev/null || die 400 'Save the destination IP first'
            fi
            state_update --argjson job "$job" '.job=$job | .run += {migration_started:true,migration_script_status:"RUNNING"} |
              if .config.require_prepare then .setup={status:"CONSUMED",detail:"Prepare hosts again before the next migration"} else . end'
        else state_update --argjson job "$job" '.job=$job'; fi
        if ! launch_worker job "$id"; then
            state_update '.job.status="FAILED" | if .job.kind=="migration" then .run.migration_script_status="FAILED" else . end'
            die 500 'Cannot start job monitor'
        fi
        if [[ $UVP_MODE == demo && $(jq -r .kind <<<"$job") == migration ]]; then
            printf 'trigger\n' >>"$UVP_STATE_DIR/control-$(jq -r .run_id <<<"$job")"
        fi
        event job "Started $(jq -r .label <<<"$job")"
        reply 202 "$job" ;;
esac
if [[ $path =~ ^/api/runs/([0-9a-f]{12})/(resume|action|cancel|export)$ ]]; then
    id=${BASH_REMATCH[1]}; op=${BASH_REMATCH[2]}
    if [[ $method == POST && $op != export ]]; then
        validate 'controlled($id;$op)' --arg id "$id" --arg op "$op"
        printf '%s\n' "$op" >>"$UVP_STATE_DIR/control-$id"
        state_update --argjson run "$VALUE" '.run=$run'
        event operator "$op"
        reply 200 "$VALUE"
    elif [[ $method == GET && $op == export ]]; then
        if jq -e --arg id "$id" '.run.id == $id' "$STATE" >/dev/null; then record=$(jq -c .run "$STATE")
        elif [[ -f $UVP_STATE_DIR/runs/$id.json ]]; then record=$(cat "$UVP_STATE_DIR/runs/$id.json")
        else die 404 'Unknown run'; fi
        # Snapshot the append-only journal boundary while the run record is
        # locked, then stream outside the lock so live checkpoint updates can proceed.
        journal="$UVP_STATE_DIR/runs/$id.events"
        bytes=0
        if [[ -f $journal ]]; then bytes=$(stat -c %s -- "$journal"); fi
        unlock_state
        printf '200\n{"run":%s,"events":[' "$record"
        if ((bytes)); then
            head -c "$bytes" -- "$journal" | jq -njr '
                foreach inputs as $e (0; .+1; (if .==1 then "" else "," end) + ($e|del(.run_id)|tojson))'
        fi
        printf ']}\n'
        exit 0
    fi
fi
die 404 'Not found'
