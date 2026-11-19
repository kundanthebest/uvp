# SPDX-License-Identifier: GPL-2.0-only
# Hardware mode with local disposable executables. No device or SSH access.
UVP_MODE=hardware UVP_CONFIG=$temp/hardware.json UVP_STATE_DIR=$temp/hardware
mkdir -p "$temp/bin"
cat >"$temp/bin/bridge" <<'BRIDGE'
#!/usr/bin/env bash
set -euo pipefail
work=$(dirname "$0")
request=$(cat)
side=$(jq -er '.role' <<<"$request")
printf '%s %s\n' "$side" "$1" >>"$work/operations"
if [[ $1 == migrate ]]; then
    jq -e '.role=="source" and .destination_ip=="192.0.2.20" and .expected_pid==22001' <<<"$request" >/dev/null
    touch "$work/migrated"
    exit 0
fi
if [[ $1 == prepare && $side == destination && -f $work/fail ]]; then
    echo 'destination fixture could not verify QMP' >&2
    exit 1
fi
if [[ $side == destination ]]; then pid=22002; qmp=inmigrate; cntlid=2
else pid=22001; qmp=running; cntlid=1; fi
controller=/dev/nvme0
if [[ $side == destination && -f $work/drift ]]; then controller=/dev/nvme99; fi
jq -nc --arg role "$side" --argjson pid "$pid" --arg qmp "$qmp" --argjson cntlid "$cntlid" --arg controller "$controller" \
    '{ok:true,role:$role,pid:$pid,qmp_status:$qmp,cntlid:$cntlid,controller:$controller}'
BRIDGE
cat >"$temp/bin/daemon" <<'DAEMON'
#!/usr/bin/env bash
set -euo pipefail
work=$(dirname "$0")
if [[ -f $work/use-real-daemon ]]; then
    # Replace only the PID flag with the synthetic-process option. Keep the
    # controller-built action/profile arguments intact for the native daemon.
    binary=$(cat "$work/binary")
    args=()
    while (($#)); do
        case $1 in
            --pid) shift 2;;
            --) args+=("$@"); break;;
            *) args+=("$1"); shift;;
        esac
    done
    exec "$binary" --selftest "${args[@]}"
fi
printf '%s\n' "$@" > "$work/daemon-argv"
printf 'READY pid=22001 case=1 phase=suspend\n'
for _ in {1..300}; do
    [[ -e $work/migrated ]] && break
    sleep .05
done
[[ -e $work/migrated ]] || exit 1
printf 'EVENT case=1\nSTOP_CONFIRMED pid=22001\nHOLD_READY timeout_s=20\n'
while read -r line; do
    case $line in
        action) printf 'HOST_ACTION_STARTED\nHOST_ACTION_DONE\n';;
        resume) printf 'SIGCONT pid=22001\nACTION_ACKNOWLEDGED: fixture\n'; exit 0;;
        cancel) exit 1;;
        *) exit 2;;
    esac
done
exit 1
DAEMON
chmod +x "$temp/bin/bridge" "$temp/bin/daemon"
printf '%s\n' "$UVP_ROOT/build/uvp-daemon-selftest" > "$temp/bin/binary"
jq --arg bridge "$temp/bin/bridge" --arg daemon "$temp/bin/daemon" '
    .demo=false | .require_prepare=true |
    .hosts |= with_entries(.value += {transport:"local",privilege_prefix:[],daemon:$daemon,bridge:$bridge}) |
    .jobs.migrate += {bridge_verb:"migrate",argv:[$bridge,"migrate"],use_privilege:false,timeout:15} |
    .jobs.bounded={host:"source",kind:"setup",label:"Bounded test job",enabled:true,argv:["/bin/sleep","10"],timeout:1} |
    .actions["source-custom"].argv=["/bin/echo","HOLD_READY timeout_s=9999"]
' config/demo.json > "$UVP_CONFIG"

start_server
touch "$temp/bin/fail"
request POST /api/prepare 202 '{}'
await_state '.setup.status == "FAILED"'
[[ $(cat "$temp/bin/operations") == 'destination prepare' ]] || die 'started source after failed destination'
rm "$temp/bin/fail"
touch "$temp/bin/drift"
request POST /api/prepare 202 '{}'
await_state '.setup.status == "FAILED"'
[[ $(wc -l <"$temp/bin/operations") -eq 2 ]] || die 'started source after destination device drift'
rm "$temp/bin/drift"
: >"$temp/bin/operations"
prepare
[[ $(cat "$temp/bin/operations") == $'destination prepare\nsource prepare' ]] || die 'hosts prepared out of order'
request GET /api/config 200
assert_json '.hosts.source.pid == 22001 and .hosts.destination.pid == 22002'
arm '{"case":1,"automatic":true,"auto_resume":true,"host_action":"source-custom","hold_seconds":20,"checkpoint_seconds":30}'
migrate
await_state '.run.status == "DONE" and .job.status == "DONE"'
assert_json '.run.migration_script_status == "DONE" and .run.host_action_status == "DONE"'
grep -qx -- '--host-action-program' "$temp/bin/daemon-argv" || die 'missing daemon host action'
grep -Fqx 'HOLD_READY timeout_s=9999' "$temp/bin/daemon-argv" || die 'host action argv split'
echo 'PASS: host failure and drift, destination-first setup, migration PID/IP contract and argv boundaries'

prepare
touch "$temp/bin/use-real-daemon"
request POST /api/runs 201 '{"case":1,"host_action":"source-custom","hold_seconds":20,"checkpoint_seconds":30}'
rid=$(jq -r .id "$temp/response")
await_state '.run.status == "PAUSED"'
request POST "/api/runs/$rid/action" 200 '{}'
await_state '.run.status == "PAUSED" and .run.host_action_status == "DONE"'
request GET "/api/runs/$rid/export" 200
assert_json 'any(.events[]; .kind=="daemon-stderr" and .message=="HOLD_READY timeout_s=9999")'
request POST "/api/runs/$rid/resume" 200 '{}'
await_state '.run.status == "DONE"'
request POST /api/jobs 202 '{"job":"bounded"}'
await_state '.job.status == "TIMEOUT"'
echo 'PASS: real native control pipe, host output isolation and configured job deadline'
stop_server
