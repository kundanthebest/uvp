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
    binary=$(cat "$work/binary")
    exec "$binary" --selftest "$@"
fi
printf '%s\n' "$@" > "$work/daemon-argv"
case_id=
while (($#)); do
    case $1 in
        --pid) echo 'Issuer was supplied at arm time' >&2; exit 2;;
        --case) case_id=$2; shift 2;;
        --) break;;
        *) shift;;
    esac
done
case $case_id in
    1) tgid=33001; tid=34001;;
    3) tgid=33003; tid=34003;;
    *) exit 2;;
esac
# stderr is kept for diagnostics. Only the daemon's stdout EVENT is authoritative.
printf 'EVENT case=%s phase=fixture tgid=99001 tid=99002 ctrl=nvme0\n' "$case_id" >&2
printf 'READY case=%s phase=fixture issuer=auto\n' "$case_id"
for _ in {1..300}; do
    [[ -e $work/migrated ]] && break
    sleep .05
done
[[ -e $work/migrated ]] || exit 1
if [[ -e $work/hold-without-event ]]; then
    printf 'HOLD_READY timeout_s=20\n'
    exit 0
fi
printf 'EVENT case=%s phase=fixture tgid=%s tid=%s ctrl=nvme0\n' "$case_id" "$tgid" "$tid"
printf 'STOP_CONFIRMED pid=%s\nHOLD_READY timeout_s=20\n' "$tgid"
while read -r line; do
    case $line in
        action) printf 'HOST_ACTION_STARTED\nHOST_ACTION_DONE\n';;
        resume) printf 'SIGCONT pid=%s\nACTION_ACKNOWLEDGED: fixture\n' "$tgid"; exit 0;;
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
request GET /api/state 200
assert_json '.setup.hosts.source.pid == 22001 and .setup.hosts.destination.pid == 22002'
arm '{"case":1,"automatic":true,"auto_resume":true,"host_action":"source-custom","hold_seconds":20,"checkpoint_seconds":30}'
assert_json '.run.issuer_tgid == null and .run.issuer_tid == null'
migrate
await_state '.run.status == "DONE" and .job.status == "DONE"'
assert_json '.run.migration_script_status == "DONE" and .run.host_action_status == "DONE"'
assert_json '.run.issuer_tgid == 33001 and .run.issuer_tid == 34001'
grep -qx -- '--host-action-program' "$temp/bin/daemon-argv" || die 'missing daemon host action'
grep -Fqx 'HOLD_READY timeout_s=9999' "$temp/bin/daemon-argv" || die 'host action argv split'
echo 'PASS: host failure and drift, destination-first setup, migration PID/IP contract and argv boundaries'

rm "$temp/bin/migrated"
prepare
arm '{"case":3,"automatic":true,"auto_resume":true,"hold_seconds":20,"checkpoint_seconds":30}'
assert_json '.run.host == "destination" and .run.issuer_tgid == null and .run.issuer_tid == null'
migrate
await_state '.run.status == "DONE" and .job.status == "DONE"'
request GET "/api/runs/$rid/export" 200
assert_json '.run.issuer_tgid == 33003 and .run.issuer_tid == 34003 and
             any(.events[]; .kind == "daemon-stderr" and (.message | contains("tgid=99001")))'
echo 'PASS: destination issuer discovered from daemon stdout while the source QMP peer launches migration'

rm "$temp/bin/migrated"
touch "$temp/bin/hold-without-event"
prepare
arm '{"case":1,"automatic":true,"auto_resume":true,"host_action":"source-custom"}'
migrate
await_state '.run.status == "FAILED" and .job.status == "DONE"'
assert_json '.run.issuer_tgid == null and .run.issuer_tid == null and (.run.auto_action_requested|not)'
rm "$temp/bin/hold-without-event"
echo 'PASS: a hold without a submission event cannot trigger automatic action'

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
