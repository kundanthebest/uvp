#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Run each long-lived operation outside the HTTP process. Only the local C
# daemon attached on the selected host owns permission to stop/release QEMU.
set -Eeuo pipefail
umask 077
source "$UVP_ROOT/controller/state.sh"
source "$UVP_ROOT/controller/transport.sh"
operation=$1
id=$2
case $operation in
    prepare|preflight) owner=setup;;
    job|run) owner=$operation;;
    *) exit 2;;
esac
[[ $id =~ ^[0-9a-f]{12}$ ]] || exit 2
relay= stream_fd= input_path= error_detail= run_id= finished=0
IO=$UVP_ROOT/build/uvp-worker-io

owns_state() {
    jq -e --arg session "$UVP_SESSION" --arg id "$id" --arg key "$owner" '
      .session==$session and (.closing|not) and .[$key].id==$id' "$STATE" >/dev/null
}
lock_current() {
    lock_state || exit 1
    if ! owns_state; then unlock_state; exit 1; fi
}
cleanup_worker() {
    local rc=$?
    trap - EXIT TERM INT HUP
    set +e
    if [[ $stream_fd ]]; then exec {stream_fd}<&-; stream_fd=; fi
    if [[ $relay ]]; then kill -TERM "$relay" 2>/dev/null; wait "$relay" 2>/dev/null; fi
    [[ ! $input_path ]] || rm -f -- "$input_path"
    if (( !finished )); then
        # An unexpected jq, exec, stream or worker error must not leave an
        # accepted operation busy forever. Recheck ownership after locking.
        flock -u 9 2>/dev/null
        exec 9>&-
        if lock_state; then
            if owns_state; then
                local message="${error_detail:-Worker stopped unexpectedly (status $rc)}"
                case $owner in
                    run) state_update --arg msg "$message" '.run += {status:(if .run.status=="CANCELLING" then "CANCELLED" else "FAILED" end),detail:$msg,ended_at:now,hold_deadline:null}' ;;
                    setup) state_update --arg msg "$message" '.setup += {status:"FAILED",detail:$msg}' ;;
                    job) state_update --arg msg "$message" '.job += {status:"FAILED",detail:$msg} |
                        if .job.run_id!=null and .run.id==.job.run_id and .config.jobs[.job.key].kind=="migration"
                        then .run.migration_script_status="FAILED" else . end' ;;
                esac
                event error "$message" "${run_id:-system}"
            fi
            unlock_state
        fi
    fi
}
trap cleanup_worker EXIT
trap 'exit 143' TERM HUP
trap 'exit 130' INT
lock_current
config=$(jq -c '.config' "$STATE")
object=$(jq -c --arg key "$owner" '.[$key]' "$STATE")
run_id=$(jq -r '.run.id // "system"' "$STATE")
unlock_state

# The stream helper forwards commands to stdin independently of the event log.
# Workers only parse 'o' records. Workload stderr and overlong stdout lines
# remain diagnostic even if they happen to look like protocol records.
stream_command() {
    local timeout=$1 method=$2 file=$3 handler=$4 line tag value
    shift 4
    [[ $timeout =~ ^[1-9][0-9]*$ ]] && ((timeout<=2678400)) || {
        error_detail='Invalid configured operation timeout'; return 1; }
    [[ -x $IO ]] || { error_detail='Build uvp-worker-io before starting the controller'; return 1; }
    exec {stream_fd}< <(exec "$IO" "$$" "$timeout" "$method" "$file" -- "$@" 9>&-)
    relay=$!
    while IFS= read -r line <&"$stream_fd"; do
        if [[ $line == t ]]; then
            owns_state || exit 1
            continue
        fi
        tag=${line%%$'\t'*}
        value=${line#*$'\t'}
        case $tag in o|e|l) "$handler" "$tag" "$value";; esac
    done
    exec {stream_fd}<&-
    stream_fd=
    STREAM_RC=0
    wait "$relay" || STREAM_RC=$?
    relay=
}

bridge_output() {
    local tag=$1 line=$2
    if [[ $tag == e ]]; then
        bridge_error+="$line"$'\n'
        if (( ${#bridge_error}>4096 )); then bridge_error=${bridge_error: -4096}; fi
    else
        if (( ${#bridge_result} + ${#line} >= 131072 )); then
            error_detail='Host bridge response exceeded 128 KiB'
            exit 1
        fi
        bridge_result+="$line"$'\n'
    fi
}
prepare_hosts() {
    local side host argv address expected pid bridge_result bridge_error
    input_path=$(mktemp "$UVP_STATE_DIR/request.XXXXXXXX")
    for side in destination source; do
        lock_current
        state_update --arg detail "$operation $side" '.setup.detail=$detail'
        unlock_state
        host=$(jq -c --arg s "$side" '.hosts[$s]' <<< "$config")
        if [[ $UVP_MODE == demo ]]; then
            if [[ $side == source ]]; then pid=12345; expected=running; else pid=23456; expected=inmigrate; fi
            bridge_result=$(jq -cn --arg s "$side" --argjson h "$host" --argjson pid "$pid" --arg q "$expected" \
                '{ok:true,role:$s,pid:$pid,controller:$h.controller,cntlid:$h.cntlid,qmp_status:$q,simulated:true}')
        else
            argv=$(jq -c --arg verb "$operation" '(.privilege_prefix // [])+[(.bridge // "/opt/uvp-orchestrator/scripts/host-bridge.sh"),$verb]' <<< "$host")
            transport_argv "$host" "$argv" || { error_detail="$side: invalid host bridge configuration"; exit 1; }
            jq -cn --arg s "$side" '{role:$s}' > "$input_path"
            bridge_result= bridge_error=
            stream_command 180 input "$input_path" bridge_output "${COMMAND[@]}"
            if (( STREAM_RC != 0 )); then
                error_detail="$side $operation failed (rc=$STREAM_RC): ${bridge_error:-${bridge_result:0:2048}}"
                exit 1
            fi
        fi
        if ! jq -es --arg s "$side" 'length==1 and (.[0]|.ok==true and .role==$s)' <<< "$bridge_result" >/dev/null; then
            error_detail="$side bridge did not confirm $operation"; exit 1
        fi
        if [[ $operation == prepare ]]; then
            if ! jq -e --argjson h "$host" --arg s "$side" '
                .pid|=if type=="number" and .==floor and .>=2 and .<=2147483647 then . else null end |
                .pid!=null and .controller==$h.controller and .cntlid==$h.cntlid and
                .qmp_status==(if $s=="source" then "running" else "inmigrate" end)' <<< "$bridge_result" >/dev/null; then
                error_detail="$side verified PID, controller/CNTLID or QMP runstate differs from the requested host configuration"; exit 1
            fi
        fi
        lock_current
        state_update --arg s "$side" --argjson result "$bridge_result" --arg verb "$operation" '
            .setup.hosts[$s]=$result |
            if $verb=="prepare" then .config.hosts[$s].pid=$result.pid else . end'
        event setup "$side $operation confirmed" "$run_id"
        unlock_state
    done
    lock_current
    if [[ $operation == prepare ]]; then
        state_update '.setup += {status:"READY",detail:"Both hosts prepared"}'
    else
        state_update '.setup += {status:"CHECKED",detail:"Preflight complete; prepare hosts next"}'
    fi
    unlock_state
}
daemon_output() {
    local tag=$1 line=$2 change=. cmd
    lock_current
    if [[ $tag != o ]]; then
        if [[ $tag == e ]]; then
            event daemon-stderr "$line" "$id"
            case $line in FAIL:*|WATCHDOG:*|RUN_FAILED*|CLEANUP:*)
                state_update --arg detail "$line" '.run.detail=$detail';; esac
        else event daemon-output "$line" "$id"; fi
        unlock_state; return 0
    fi
    event daemon "$line" "$id"
    case $line in
        'READY '*) change='.run += {status:"ARMED",detail:"Hooks attached; start migration when ready"}';;
        'HOLD_READY '*) change='.run += {status:"PAUSED",hold_deadline:(now+.run.hold_seconds),detail:"Owned QEMU stop confirmed"}';;
        HOST_ACTION_STARTED) change='.run += {status:"HOST_ACTION",host_action_status:"RUNNING"}';;
        HOST_ACTION_DONE) change='.run += {status:"PAUSED",host_action_status:"DONE",detail:"Host action completed; checkpoint remains held"}';;
        HOST_ACTION_FAILED*) change='.run += {host_action_status:"FAILED",detail:"Host action failed; daemon cleanup releases its target"}';;
        'SIGCONT pid='*) change='.run += {status:"RELEASED",hold_deadline:null,detail:"QEMU released; guest runstate is not inferred"}';;
        ACTION_EXEC:*) change='if .run.guest_action!="none" then .run.guest_action_status="WAITING FOR ACK" else . end';;
        ACTION_ACKNOWLEDGED:*) change='if .run.guest_action!="none" then .run.guest_action_status="ACKNOWLEDGED" else . end';;
        FAIL:*|WATCHDOG:*|RUN_FAILED*|CLEANUP:*) change='.run.detail=$line';;
    esac
    if [[ $change != . ]]; then
        state_update --arg line "$line" "if .run.status==\"CANCELLING\" then . else $change end"
    fi
    # Both manual and automatic dispatch reserve the visible action state
    # under the API lock before exposing the command to the live daemon.
    cmd=$(jq -r '.run | if .automatic and .status=="PAUSED" then
        if .host_action_status=="READY" and (.auto_action_requested|not) then "action"
        elif (.host_action_status=="NONE" or .host_action_status=="DONE") and .auto_resume and
               (.auto_resume_requested|not) then "resume" else empty end else empty end' "$STATE")
    if [[ $cmd ]]; then
        if [[ $cmd == action ]]; then
            state_update '.run += {auto_action_requested:true,status:"HOST_ACTION",host_action_status:"RUNNING"}'
        else
            state_update '.run += {auto_resume_requested:true,status:"RESUMING"}'
        fi
        printf '%s\n' "$cmd" >> "$UVP_STATE_DIR/control-$id"
        event operator "$cmd" "$id"
    fi
    unlock_state
}
run_daemon() {
    local host argv limit
    if [[ $UVP_MODE == demo ]]; then
        mapfile -t COMMAND < <(jq -r --arg sim "$UVP_ROOT/controller/simulator.sh" \
            '[$sim,.case,.pid,.checkpoint_seconds,.hold_seconds,.host_action,.guest_action][]' <<< "$object")
    else
        host=$(jq -c --argjson r "$object" '.hosts[$r.host]' <<< "$config")
        argv=$(jq -ce --argjson r "$object" '
            . as $c | .hosts[$r.host] as $h |
            ($h.privilege_prefix // []) +
            [$h.daemon,"--pid",$r.pid,"--case",$r.case,"--controller",$r.controller,
             "--cntlid",$r.cntlid,"--bpf",$h.bpf,"--timeout",$r.checkpoint_seconds,"--control-stdin",
             "--hold-timeout",$r.hold_seconds,"--action-timeout",($c.action_timeout//300)] +
            (if $r.symbol!="" then ["--phase-symbol",$r.symbol] else [] end) +
            (if $r.case==5 then [$r.selectors|to_entries[] | ("--"+(.key|gsub("_";"-"))),.value] else [] end) +
            (if $r.host_action!="none" then ($c.actions[$r.host_action].argv as $a |
                ["--host-action-program",$a[0]]+[$a[1:][]|"--host-action-arg",.]) else [] end) +
            ["--"] + (if $r.guest_action!="none" then $c.actions[$r.guest_action].argv else ["/bin/true"] end)
            | map(tostring)' <<< "$config")
        transport_argv "$host" "$argv" || { error_detail='Invalid checkpoint daemon or transport configuration'; exit 1; }
    fi
    limit=$(jq -nr --argjson r "$object" --argjson cfg "$config" '$r.checkpoint_seconds+$r.hold_seconds+($cfg.action_timeout//300)+30')
    stream_command "$limit" control "$UVP_STATE_DIR/control-$id" daemon_output "${COMMAND[@]}"
    lock_current
    state_update --argjson rc "$STREAM_RC" '
        .run += {status:(if .run.status=="CANCELLING" then "CANCELLED" elif $rc==0 then "DONE" else "FAILED" end),
                 returncode:$rc,ended_at:now,hold_deadline:null} |
        if $rc!=0 and .run.host_action_status=="RUNNING" then .run.host_action_status="FAILED / CHECK TARGET" else . end |
        if $rc==0 then .run.detail="Checkpoint cycle complete. Verify migration and fio separately." else . end'
    event exit "Daemon exited rc=$STREAM_RC; migration outcome remains unverified" "$id"
    unlock_state
}
job_output() {
    lock_current
    event job-output "$2" "$run_id"
    unlock_state
}
run_job() {
    local profile side host argv input_method=none input_file=- limit kind
    run_id=$(jq -r '.run_id // "system"' <<< "$object")
    profile=$(jq -c --argjson job "$object" '.jobs[$job.key]' <<< "$config")
    kind=$(jq -r '.kind' <<< "$profile"); side=$(jq -r '.host' <<< "$profile")
    limit=$(jq -r '.timeout // 300' <<< "$profile")
    if [[ $UVP_MODE == demo ]]; then
        job_output o 'SIMULATION: configured job completed; no hardware action'
        STREAM_RC=0
    else
        host=$(jq -c --arg s "$side" '.hosts[$s]' <<< "$config")
        argv=$(jq -c --argjson h "$host" '(if .use_privilege then ($h.privilege_prefix//[]) else [] end)+.argv' <<< "$profile")
        transport_argv "$host" "$argv" || { error_detail='Invalid job or transport configuration'; exit 1; }
        if [[ $(jq -r '.bridge_verb // ""' <<< "$profile") == migrate ]]; then
            input_path=$(mktemp "$UVP_STATE_DIR/request.XXXXXXXX")
            jq -c '{role:"source",destination_ip:.hosts.destination.address,expected_pid:.hosts.source.pid}' <<< "$config" >"$input_path"
            input_method=input; input_file=$input_path
        fi
        stream_command "$limit" "$input_method" "$input_file" job_output "${COMMAND[@]}"
    fi
    lock_current
    state_update --argjson rc "$STREAM_RC" --arg mode "$UVP_MODE" --arg kind "$kind" --arg rid "$run_id" '
        .job += {returncode:$rc,status:(if $rc==124 then "TIMEOUT" elif $rc==0 then "DONE" else "FAILED" end)} |
        if $kind=="migration" and .run.id==$rid then
            .run.migration_script_status=(if $mode=="demo" and $rc==0 then "SIMULATED" else .job.status end) |
            .run.migration_script_returncode=$rc else . end'
    event job "Job exited $STREAM_RC; remote/guest effects require independent verification" "$run_id"
    unlock_state
}
case $operation in
    prepare|preflight) prepare_hosts;;
    run) run_daemon;;
    job) run_job;;
esac
finished=1
