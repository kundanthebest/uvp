#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Exercise the HTML form workflow with plain HTTP and no browser script engine.
set -euo pipefail
umask 077
root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
tmp=$(mktemp -d)
pid=''
cleanup() {
    local rc=$?
    if ((rc)); then cat "$tmp"/{server.log,body} >&2 2>/dev/null || :; fi
    if [[ -n $pid ]]; then kill -TERM "$pid" 2>/dev/null || :; wait "$pid" || :; fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT
"$root/build/uvp-controller" --root "$root" --config "$root/config/demo.json" --data-dir "$tmp/state" --port 0 >"$tmp/server.log" 2>&1 &
pid=$!
url=''
for _ in {1..150}; do
    url=$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*\).*|\1|p' "$tmp/server.log" | head -1)
    [[ -z $url ]] || break
    kill -0 "$pid" 2>/dev/null || break
    sleep .05
done
if [[ -z $url && -z ${GITHUB_ACTIONS:-} ]] && grep -Eiq '(bind|socket).*:( Permission denied| Operation not permitted)' "$tmp/server.log"; then
    echo 'SKIP: loopback TCP restricted for HTML form test'
    exit
fi
[[ -n $url ]]
c=(curl -sS --noproxy '*' --max-time 20)
auth=(-u uvp:uvp-demo)
post() {
    local op=$1 expected=$2 body=$3 result
    result=$("${c[@]}" "${auth[@]}" -H "Origin: $url" -o "$tmp/body" -w '%{http_code}' --data-raw "$body" "$url$op")
    [[ $result == "$expected" ]] || { echo "$op returned $result instead of $expected" >&2; return 1; }
}
state() {
    "${c[@]}" -f -H 'Authorization: Bearer uvp-demo' "$url/api/state"
}
await_state() {
    local condition=$1 stop=$((SECONDS+25))
    while ((SECONDS < stop)); do
        if state | jq -e "$condition" > /dev/null; then return; fi
        sleep .15
    done
    echo "State did not satisfy $condition" >&2; state >&2; return 1
}
[[ $("${c[@]}" -o /dev/null -w '%{http_code}' "$url/forms") == 401 ]]
"${c[@]}" "${auth[@]}" -f "$url/forms" -o "$tmp/page"
grep -q 'Start live migration' "$tmp/page"
if grep -qi '<script' "$tmp/page"; then echo 'Executable browser script in the forms dashboard' >&2; exit 1; fi
[[ $("${c[@]}" "${auth[@]}" -o /dev/null -w '%{http_code}' -H 'Origin: http://example.invalid' --data 'op=prepare' "$url/forms") == 403 ]]
hostfields='source_address=192.0.2.10&source_user=uvp&source_ssh_port=22&source_controller=%2Fdev%2Fnvme0&source_cntlid=1&destination_address=192.0.2.20&destination_user=uvp&destination_ssh_port=22&destination_controller=%2Fdev%2Fnvme1&destination_cntlid=2'
post /forms 303 "op=hosts&$hostfields"
post /forms 400 'op=hosts&op=prepare'
post /forms 400 'op=bad%00'
post /forms 303 'op=prepare'
await_state '.setup.status=="READY"'
post /forms 303 'op=arm&phase=1&host_action=none&guest_action=none&hold_seconds=20&checkpoint_seconds=40&automatic=on&auto_resume=on'
await_state '.run.status=="ARMED"'
rid=$(state | jq -er '.run.id')
post /forms 409 'op=migrate&id=000000000000&job=migrate'
post /forms 303 "op=migrate&id=$rid&job=migrate"
await_state '.run.status=="DONE"'
post /forms/export 200 "id=$rid"
jq -e --arg rid "$rid" '.run.id==$rid and (.events|length)>0' "$tmp/body" >/dev/null
echo 'PASS: authenticated HTML forms configure hosts, prepare, arm, migrate, release and export with no JavaScript'
