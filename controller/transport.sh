# SPDX-License-Identifier: GPL-2.0-only
# Convert trusted server profiles to exec arguments. OpenSSH sends one remote
# command string; quote each argv element for the remote POSIX shell.
transport_argv() {
    local host=$1 argv=$2 target port identity known quoted transport
    local target_re='^[][[:alnum:]_.@:-]+$'
    local -a words
    local restrictions='type=="array" and length>0 and length<=600 and
      all(.[]; type=="string" and length<4096 and (explode|all(.[]; .!=0 and .!=10 and .!=13)))
      and (.[0]|startswith("/"))'
    jq -e "$restrictions" <<< "$argv" >/dev/null || { echo 'Invalid configured command arguments' >&2; return 1; }
    mapfile -t words < <(jq -r '.[]' <<< "$argv")
    transport=$(jq -r '.transport // "local"' <<< "$host")
    if [[ $transport == local ]]; then COMMAND=("${words[@]}"); return 0; fi
    [[ $transport == ssh ]] || { echo 'Unsupported host transport' >&2; return 1; }
    target=$(jq -r '.ssh_target' <<< "$host")
    port=$(jq -r '.ssh_port // 22' <<< "$host")
    [[ $target =~ $target_re && $target != -* && $port =~ ^[1-9][0-9]{0,4}$ ]] &&
        ((port <= 65535)) || { echo 'Invalid configured SSH target or port' >&2; return 1; }
    identity=$(jq -r '.identity_file // empty' <<< "$host")
    known=$(jq -r '.known_hosts_file // empty' <<< "$host")
    COMMAND=(/usr/bin/ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10
        -o ServerAliveInterval=5 -o ServerAliveCountMax=3)
    [[ ! $identity ]] || COMMAND+=(-i "$identity")
    [[ ! $known ]] || COMMAND+=(-o "UserKnownHostsFile=$known")
    quoted=$(jq -r 'map(@sh)|join(" ")' <<< "$argv")
    COMMAND+=(-p "$port" -- "$target" "$quoted")
}
