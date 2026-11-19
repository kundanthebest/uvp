#!/bin/bash -p
# SPDX-License-Identifier: GPL-2.0-only
# Fixed privileged SSH entry point. A request never supplies an executable.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LANG=C LC_ALL=C
umask 027
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
qmp_helper=$(dirname -- "$script_dir")/build/uvp-qmp
config=/etc/uvp/host.json

fail() { jq -nc --arg e "$*" '{ok:false,error:$e}'; exit 1; }

# Check each directory through the filesystem root, including ancestors of
# symlinks such as /bin. Runtime files may not contain any symlink.
trusted_chain() {
    local path=$1 allow_links=$2 ids uid mode
    [[ $path == /* && $path != *$'\n'* && /${path#/}/ != */../* ]] || return 1
    while :; do
        if [[ -L $path ]]; then
            [[ $allow_links == yes && $(stat -c %u -- "$path") == 0 ]] || return 1
        elif [[ -e $path ]]; then
            ids=$(stat -c '%u %a' -- "$path") || return 1
            read -r uid mode <<<"$ids"
            (( uid == 0 && (8#$mode & 022) == 0 )) || return 1
        fi
        [[ $path != / ]] || break
        path=$(dirname -- "$path") || return 1
    done
}

trusted_file() {
    local resolved
    trusted_chain "$1" yes || return 1
    resolved=$(realpath -e -- "$1") || return 1
    trusted_chain "$resolved" no && [[ -f $resolved ]] || return 1
    [[ ${2:-} != executable || -x $resolved ]] || return 1
    printf '%s\n' "$resolved"
}

checked_argv() {
    local key=$1 program trusted_script
    local -n vector=$2
    # Config grammar below excludes control characters before line decoding.
    mapfile -t vector < <(jq -r --arg key "$key" '.[$key][]' "$config")
    program=$(trusted_file "${vector[0]}" executable) || fail "Untrusted $key executable"
    vector[0]=$program
    case ${program##*/} in
        bash|dash|sh|ksh|zsh)
            (( ${#vector[@]} >= 2 )) || fail "$key requires a trusted absolute script"
            trusted_script=$(trusted_file "${vector[1]}") || fail "$key requires a trusted absolute script"
            vector[1]=$trusted_script ;;
    esac
}

load_config() {
    config=$(trusted_file "$config") || fail 'Check ownership, modes and path of /etc/uvp/host.json'
    jq -se '
        def text: type=="string" and length<=4096 and (explode|all(.>=32 and .!=127));
        def abs: text and startswith("/") and (split("/")|all(.!=".."));
        def argv: type=="array" and length>=1 and length<=64 and all(.[];text) and (.[0]|abs);
        def integer($lo;$hi): type=="number" and .==floor and .>=$lo and .<=$hi;
        length==1 and (.[0] |
          type=="object" and (.role=="source" or .role=="destination") and
          (.controller|text and test("^/dev/nvme[0-9]+$")) and (.cntlid|integer(0;65535)) and
          ([.pidfile,.qmp_socket,.launch_log,.qemu_executable,.daemon,.bpf]|all(.[];abs)) and
          (.launch_argv|argv) and (.role!="source" or (.migration_argv|argv)) and
          ((.launch_timeout // 90)|integer(1;120)) and ((.migration_timeout // 1700)|integer(5;7200)) and
          ((.environment // {})|type=="object" and all(to_entries[];
            (.key|test("^[A-Z][A-Z0-9_]*$") and (test("^(LD_|BASH|SHELLOPTS$|ENV$|PATH$|IFS$|CDPATH$|GCONV_PATH$|GLIBC_TUNABLES$|LOCPATH$|PYTHON)")|not)) and (.value|text))))
    ' "$config" >/dev/null || fail 'Invalid host config, paths, limits or environment'
    local -a settings
    mapfile -t settings < <(jq -r '.role,.controller,.cntlid,.pidfile,.qmp_socket,.launch_log,.qemu_executable,.daemon,.bpf,(.launch_timeout // 90),(.migration_timeout // 1700)' "$config")
    role=${settings[0]} controller=${settings[1]} cntlid=${settings[2]} pidfile=${settings[3]}
    qmp=${settings[4]} log=${settings[5]} qemu=${settings[6]} daemon=${settings[7]} bpf=${settings[8]}
    launch_timeout=${settings[9]} migration_timeout=${settings[10]}
    local path
    qmp_helper=$(trusted_file "$qmp_helper" executable) || fail 'Build and install the native QMP helper'
    for path in "$pidfile" "$qmp" "$log"; do
        trusted_chain "$path" no || fail "Unsafe runtime path: $path"
    done
    qemu=$(trusted_file "$qemu" executable) || fail 'Untrusted QEMU executable'
    checked_argv launch_argv launch
    if [[ $role == source ]]; then
        checked_argv migration_argv migration
        trusted_file /usr/bin/timeout executable >/dev/null || fail 'Untrusted timeout executable'
    fi
    mapfile -t env_entries < <(jq -r '(.environment // {})|to_entries[]|"\(.key)=\(.value)"' "$config")
}

# Output the VM status object or null. Errors never signal the pidfile process.
inspect_vm() {
    local pid status
    if [[ ! -e $pidfile ]]; then echo null; return 0; fi
    [[ -f $pidfile && $(stat -c %s -- "$pidfile") -le 32 ]] || { echo 'Invalid QEMU pidfile' >&2; return 1; }
    pid=$(cat -- "$pidfile") || return 1
    [[ $pid =~ ^[1-9][0-9]{0,9}$ ]] && (( pid>=2 && pid<=2147483647 )) || { echo 'Invalid QEMU PID' >&2; return 1; }
    status=$("$qmp_helper" "$qmp" "$pid" "$qemu") || return 1
    jq -nc --argjson pid "$pid" --arg status "$status" '{pid:$pid,qmp_status:$status}'
}

expected_state() { if [[ $role == source ]]; then echo running; else echo inmigrate; fi; }

check() {
    local name=$1 detail=$2; shift 2
    local ok=false
    if "$@" >/dev/null 2>&1; then ok=true; fi
    jq -nc --arg n "$name" --arg d "$detail" --argjson ok "$ok" '{name:$n,detail:$d,ok:$ok}'
}

preflight() {
    local checks vm err='' tracefs path event
    tracefs=/sys/kernel/tracing
    [[ -d $tracefs/events ]] || tracefs=/sys/kernel/debug/tracing
    checks=$({
        check root 'Privileged host bridge' test "$EUID" = 0
        check architecture "$(uname -m)" test "$(uname -m)" = x86_64
        check BTF /sys/kernel/btf/vmlinux test -f /sys/kernel/btf/vmlinux
        check daemon "$daemon" trusted_file "$daemon" executable
        check bpf "$bpf" trusted_file "$bpf"
        check controller "$controller" test -c "$controller"
        for event in raw_syscalls/sys_enter raw_syscalls/sys_exit nvme/nvme_complete_rq; do
            check "tracepoint:$event" "$tracefs/events/$event" test -d "$tracefs/events/$event"
        done
        check nvme_init_request 'Kernel probe target' awk '$3=="nvme_init_request"{ok=1} END{exit !ok}' /proc/kallsyms
    } | jq -sc .)
    if ! vm=$(inspect_vm 2>&1); then err=$vm; vm=null; fi
    jq -nc --arg role "$role" --arg device "$controller" --argjson id "$cntlid" --argjson checks "$checks" \
       --argjson vm "$vm" --arg expected "$(expected_state)" --arg err "$err" '
          {ok:($checks|all(.[];.ok)),role:$role,controller:$device,cntlid:$id,checks:$checks,
           ready:($vm.qmp_status==$expected)} + ($vm // {}) + (if $err!="" then {vm_error:$err} else {} end)'
}

prepare() {
    local facts vm expected deadline last launcher='' launched=false rc
    facts=$(preflight)
    jq -e .ok <<<"$facts" >/dev/null || fail "Host preflight failed: $(jq -r '[.checks[]|select(.ok|not)|.name]|join(", ")' <<<"$facts")"
    vm=$(inspect_vm 2>&1) || fail "$vm"
    if [[ $vm == null ]]; then
        [[ ! -e $qmp ]] || fail 'QMP socket exists without a QEMU pidfile; inspect the VM'
        # Do not chmod existing parent directories (some configurations log to /var/log or /run).
        mkdir -p -m 0750 -- "$(dirname -- "$pidfile")" "$(dirname -- "$qmp")" "$(dirname -- "$log")"
        setsid env -i "PATH=$PATH" LANG=C.UTF-8 "${env_entries[@]}" "${launch[@]}" \
            9>&- </dev/null >>"$log" 2>&1 &
        launcher=$!; launched=true
    fi
    expected=$(expected_state); deadline=$((SECONDS+launch_timeout)); last='pidfile has not appeared'
    while (( SECONDS < deadline )); do
        if vm=$(inspect_vm 2>&1); then
            if jq -e --arg s "$expected" '.qmp_status==$s' <<<"$vm" >/dev/null; then
                jq -nc --arg role "$role" --arg d "$controller" --argjson id "$cntlid" --argjson v "$vm" --argjson l "$launched" \
                   '{ok:true,role:$role,controller:$d,cntlid:$id,launched:$l}+$v'
                return 0
            fi
            last="QMP reports $(jq -r '.qmp_status // "no VM"' <<<"$vm")"
        else last=$vm; fi
        if [[ -n $launcher ]] && ! kill -0 "$launcher" 2>/dev/null; then
            rc=0; wait "$launcher" || rc=$?
            (( rc == 0 )) || fail "VM launcher failed (rc=$rc). See $log"
            launcher=''
        fi
        sleep .2
    done
    fail "VM not ready ($last); expected $expected. Inspect $log"
}

valid_ipv4() {
    local addr=$1 oct
    local -a parts
    [[ $addr =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -ra parts <<<"$addr"
    for oct in "${parts[@]}"; do
        [[ $oct == 0 || $oct != 0* ]] && (( 10#$oct < 256 )) || return 1
    done
    [[ $addr != 0.0.0.0 ]] && (( 10#${parts[0]} < 224 ))
}

migrate() {
    local ip vm pid pg rc=0 caught=0 start
    [[ $role == source ]] || fail 'Migration must run on the source'
    ip=$(jq -er '.destination_ip | select(type=="string" and (explode|all(.>=32 and .<=126)))' "$request") || fail 'Missing destination IPv4 address'
    valid_ipv4 "$ip" || fail 'Expected a unicast destination IPv4 address'
    vm=$(inspect_vm 2>&1) || fail "$vm"
    jq -e '.qmp_status=="running"' <<<"$vm" >/dev/null || fail 'Source VM must be running'
    pid=$(jq -r .pid <<<"$vm")
    jq -e --argjson pid "$pid" '(has("expected_pid")|not) or (.expected_pid==$pid)' "$request" >/dev/null || fail 'Source QEMU PID changed; prepare and arm again'
    printf 'UVP migration: source PID=%s destination=%s\n' "$pid" "$ip"
    trap 'caught=129' HUP; trap 'caught=130' INT; trap 'caught=143' TERM
    # A separate group isolates the migration driver from both prepared QEMUs.
    # timeout inherits fd 9 so the host lock survives an SSH transport loss.
    setsid env -i "PATH=$PATH" LANG=C.UTF-8 "${env_entries[@]}" "SOURCE_QMP=$qmp" \
        /usr/bin/timeout --signal=TERM --kill-after=5s "${migration_timeout}s" "${migration[@]}" "$ip" </dev/null &
    pg=$!
    if (( ! caught )); then wait "$pg" || rc=$?; fi
    if (( caught )); then
        kill -TERM -- "-$pg" 2>/dev/null || kill -TERM "$pg" 2>/dev/null || :
        start=$SECONDS
        while kill -0 -- "-$pg" 2>/dev/null && (( SECONDS-start < 6 )); do sleep .1; done
        kill -KILL -- "-$pg" 2>/dev/null || :
        wait "$pg" 2>/dev/null || :
        rc=$caught
    fi
    trap - HUP INT TERM
    return "$rc"
}

main() {
    [[ $# == 1 && ($1 == prepare || $1 == preflight || $1 == migrate) ]] || fail 'Usage: host-bridge.sh preflight|prepare|migrate'
    (( EUID==0 )) || fail 'Run the host bridge as root'
    load_config
    trusted_chain /run/uvp no || fail 'Unsafe host lock directory'
    if [[ ! -d /run/uvp ]]; then mkdir -m 0700 /run/uvp || [[ -d /run/uvp ]] || fail 'Could not create host lock directory'; fi
    request=$(mktemp /run/uvp/request.XXXXXXXX) || fail 'Could not create request file'
    trap 'rm -f -- "$request"' EXIT
    head -c 16385 >"$request"
    (( $(stat -c %s -- "$request") <= 16384 )) || fail 'Request exceeds 16 KiB'
    if [[ ! -s $request ]]; then printf '{}\n' >"$request"; fi
    jq -se --arg role "$role" 'length==1 and (.[0]|type=="object" and ((has("role")|not) or .role==$role))' "$request" >/dev/null || fail 'Invalid request or role mismatch'
    if [[ $1 == preflight ]]; then
        local result
        result=$(preflight); printf '%s\n' "$result"
        jq -e '.ok' <<<"$result" >/dev/null
        return
    fi
    trusted_chain /run/uvp/host-bridge.lock no || fail 'Unsafe host lock'
    exec 9>>/run/uvp/host-bridge.lock
    flock -n 9 || fail 'Another prepare or migration is already running'
    "$1"
}

# Expose pure validation helpers to the local shell test harness.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
