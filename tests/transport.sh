#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# The SSH adapter must preserve the exact profile argv at the remote POSIX shell.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/controller/transport.sh"
host='{"transport":"ssh","ssh_target":"uvp@192.0.2.20","ssh_port":22}'
argv=$(jq -cn --arg value "O'Brien; two words" '["/bin/echo",$value,""]')
transport_argv "$host" "$argv"
[[ " ${COMMAND[*]} " == *' StrictHostKeyChecking=yes '* ]]
[[ $(/bin/sh -c "${COMMAND[-1]}") == "O'Brien; two words " ]]
if transport_argv '{"transport":"ssh","ssh_target":"-bad"}' "$argv" 2>/dev/null; then
    echo 'FAIL: SSH accepted an option as a target' >&2; exit 1
fi
if transport_argv "$host" '["/bin/echo","line\nbreak"]' 2>/dev/null; then
    echo 'FAIL: transport accepted multiline argv' >&2; exit 1
fi
echo 'PASS: SSH strict host-key checking, argument quoting and invalid target rejection'
