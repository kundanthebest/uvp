#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Auth and body limits are enforced by the loopback HTTP server.
set -euo pipefail
api=$UVP_ROOT/controller/api.sh
declare -A fields=()
status=200
message=''
reply=''
call_api() {
    local response
    if ! response=$("$api" "$1" "$2" <<< "$3"); then
        # api.sh normally returns its status in-band.
        status=500; message='The controller could not process this request.'; return 1
    fi
    status=${response%%$'\n'*}
    reply=${response#*$'\n'}
    if [[ ! $status =~ ^[1-5][0-9][0-9]$ ]] || ! jq -e 'type == "object"' >/dev/null <<< "$reply"; then
        status=500; message='Invalid response from the controller.'; return 1
    fi
    if ((status >= 400)); then
        message=$(jq -r '.error // "Operation failed"' <<< "$reply")
        return 1
    fi
}
decode_value() {
    local value=${1//+/ } pair
    decoded=''
    while [[ $value == *%* ]]; do
        decoded+=${value%%\%*}; value=${value#*%}; pair=${value:0:2}
        [[ $pair =~ ^[0-9a-fA-F]{2}$ && $pair != 00 ]] || return 1
        printf -v pair '%b' "\\x$pair"
        decoded+=$pair; value=${value:2}
    done
    decoded+=$value
    [[ ! $decoded =~ [[:cntrl:]] ]]
}
read_form() {
    local body part name decoded
    body=$(cat)
    [[ -n $body && ${#body} -le 16384 ]] || return 1
    local -a elements
    IFS='&' read -ra elements <<< "$body"
    ((${#elements[@]} <= 64)) || return 1
    for part in "${elements[@]}"; do
        [[ $part == *=* ]] || return 1
        name=${part%%=*}
        [[ $name =~ ^[a-z][a-z0-9_]{0,40}$ ]] || return 1
        [[ ! -v fields[$name] ]] || return 1
        decode_value "${part#*=}" || return 1
        fields[$name]=$decoded
    done
}
form_object() {
    local -a args=()
    local name
    for name in "${!fields[@]}"; do args+=("$name" "${fields[$name]}"); done
    jq -cn --args 'reduce range(0; $ARGS.positional|length; 2) as $i ({}; .[$ARGS.positional[$i]]=$ARGS.positional[$i+1])' -- "${args[@]}"
}
mutate() {
    local data body rid
    data=$(form_object)
    case ${fields[op]:-} in
        hosts|prepare|preflight)
            if [[ ${fields[op]} == hosts || -v fields[source_address] || -v fields[destination_address] ]]; then
                body=$(jq -c 'def host($s): with_entries(select(.key|startswith($s+"_"))|.key |= ltrimstr($s+"_")); {source:host("source"),destination:host("destination")}' <<< "$data")
                call_api POST /api/hosts "$body" || return 1
            fi
            if [[ ${fields[op]} != hosts ]]; then call_api POST "/api/${fields[op]}" '{}'; fi ;;
        arm)
            body=$(jq -c '{case:.phase,target_host:.target_host,host_action,guest_action,hold_seconds,checkpoint_seconds,destructive_ack,automatic:(.automatic=="on"),auto_resume:(.auto_resume=="on"),selectors:{opcode,queue,nsid,nsid_mask,cdw10,cdw10_mask,cdw11,cdw11_mask}} + (if (.pid // "") != "" then {pid} else {} end)' <<< "$data")
            call_api POST /api/runs "$body" ;;
        migrate)
            [[ ${fields[id]:-} =~ ^[a-f0-9]{12}$ ]] || { status=409; message='Load the eBPF hook first.'; return 1; }
            body=$(jq -cn --arg job "${fields[job]:-migrate}" --arg rid "${fields[id]}" '{job:$job,run_id:$rid}')
            call_api POST /api/jobs "$body" ;;
        job)
            body=$(jq -c '{job}' <<< "$data"); call_api POST /api/jobs "$body" ;;
        action|cancel|resume)
            rid=${fields[id]:-}
            [[ $rid =~ ^[a-f0-9]{12}$ ]] || { status=400; message='Invalid run ID.'; return 1; }
            call_api POST "/api/runs/$rid/${fields[op]}" '{}' ;;
        *) status=400; message='Unknown form operation.'; return 1 ;;
    esac
}
if [[ $1 == POST ]]; then
    if ! read_form; then
        status=400; message='Invalid form submission.'
    elif [[ $2 == /forms/export ]]; then
        rid=${fields[id]:-}
        if [[ ! $rid =~ ^[a-f0-9]{12}$ ]]; then
            printf '400\n{"error":"Invalid run ID"}\n'
        else
            exec "$api" GET "/api/runs/$rid/export" </dev/null
        fi
        exit
    elif mutate; then
        printf '303\n'; exit
    fi
fi
if [[ $2 == /forms/export ]]; then
    printf '%s\n' "$status"; jq -cn --arg err "$message" '{error:$err}'; exit
fi
render_status=$status
render_message=$message
if ! call_api GET /api/config '{}'; then printf '%s\nController configuration unavailable.\n' "$status"; exit; fi
config=$reply
if ! call_api GET /api/state '{}'; then printf '%s\nController state unavailable.\n' "$status"; exit; fi
# Stream the state via stdin to allow large event records.
html=$(jq -r --argjson cfg "$config" --arg error "$render_message" -f "$UVP_ROOT/controller/forms.jq" <<< "$reply")
printf '%s\n%s\n' "$render_status" "$html"
