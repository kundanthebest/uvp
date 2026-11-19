#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Exercise the installed API contract using a browser-equivalent HTTP client.
# Fall back to invoking the same handler directly if local sockets are prohibited.
set -euo pipefail
umask 077
export UVP_ROOT
UVP_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$UVP_ROOT"
export UVP_TOKEN=uvp-test-token-for-disposable-controller
temp=$(mktemp -d)
server_pid= api_initialized=false transport=
api=$UVP_ROOT/controller/api.sh
export UVP_CONFIG UVP_STATE_DIR UVP_MODE
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
stop_server() {
    if [[ -n $server_pid ]]; then
        kill -TERM "$server_pid" 2>/dev/null || :
        wait "$server_pid" || :
        server_pid=
    elif $api_initialized; then
        "$api" shutdown > /dev/null || :
    fi
    api_initialized=false
}
cleanup() {
    local rc=$?
    if ((rc)); then
        cat "$temp/server.log" "$temp/response" >&2 2>/dev/null || :
    fi
    stop_server
    rm -rf -- "$temp"
}
trap cleanup EXIT
start_server() {
    mkdir -p "$UVP_STATE_DIR"
    local args=(--root "$UVP_ROOT" --config "$UVP_CONFIG" --data-dir "$UVP_STATE_DIR" --port 0)
    [[ $UVP_MODE != hardware ]] || args+=(--hardware)
    if [[ $transport != direct ]]; then
        "$UVP_ROOT/build/uvp-controller" "${args[@]}" >"$temp/server.log" 2>&1 &
        server_pid=$!
        local end=$((SECONDS + 15))
        while kill -0 "$server_pid" 2>/dev/null && ((SECONDS < end)); do
            url=$(sed -n 's/.*\(http:\/\/127\.0\.0\.1:[0-9][0-9]*\).*/\1/p' "$temp/server.log" | head -n1)
            if [[ -n $url ]] && curl -fsS --noproxy '*' --max-time 1 "$url/api/info" >/dev/null 2>&1; then
                transport=http
                return
            fi
            sleep .05
        done
        if [[ -n ${GITHUB_ACTIONS:-} ]] || ! grep -Eiq '(bind|socket).*:( Permission denied| Operation not permitted)' "$temp/server.log"; then
            die 'native HTTP listener failed to start'
        fi
        wait "$server_pid" || :
        server_pid=
        transport=direct
        echo 'SKIP: loopback TCP is prohibited here; exercising the handler directly.'
    fi
    "$api" init > /dev/null
    api_initialized=true
}
request() {
    local method=$1 path=$2 expected=$3 data=${4:-} status
    if [[ $transport == http ]]; then
        local args=(-sS --noproxy '*' --max-time 15 --request "$method" -H "Authorization: Bearer $UVP_TOKEN")
        [[ $method != POST ]] || args+=(-H 'Content-Type: application/json' --data-binary "$data")
        status=$(curl "${args[@]}" -o "$temp/response" -w '%{http_code}' "$url$path")
    else
        "$api" "$method" "$path" <<<"$data" > "$temp/reply"
        IFS= read -r status < "$temp/reply"
        tail -n +2 "$temp/reply" > "$temp/response"
    fi
    if [[ $status != "$expected" ]]; then
        cat "$temp/response" >&2
        die "$method $path returned $status, expected $expected"
    fi
    jq -e 'type == "object"' "$temp/response" >/dev/null || die "invalid JSON on $method $path"
}
assert_json() {
    jq -e "$1" "$temp/response" > /dev/null || die "response does not match $1"
}
await_state() {
    local query=$1 until_time=$((SECONDS + ${2:-25}))
    while ((SECONDS <= until_time)); do
        request GET /api/state 200
        if jq -e "$query" "$temp/response" >/dev/null; then return; fi
        sleep .07
    done
    die "timed out waiting for $query"
}
prepare() {
    request POST /api/prepare 202 '{}'
    await_state '.setup.status == "READY"'
}
arm() {
    request POST /api/runs 201 "$1"
    rid=$(jq -er '.id | select(test("^[a-f0-9]{12}$"))' "$temp/response")
    await_state '.run.status == "ARMED"'
}
migrate() { request POST /api/jobs 202 '{"job":"migrate"}'; }
cancel() {
    request POST "/api/runs/$rid/cancel" 200 '{}'
    await_state '.run.status == "CANCELLED"'
}
http_status() {
    local expected=$1 path=$2
    shift 2
    local value
    value=$(curl -sS --noproxy '*' --max-time 8 -o "$temp/response" -w '%{http_code}' "$@" "$url$path")
    [[ $value == "$expected" ]] || die "HTTP $path returned $value, expected $expected"
}
UVP_MODE=demo UVP_CONFIG=$temp/demo.json UVP_STATE_DIR=$temp/demo
jq '.require_prepare=true | .actions["source-disabled"] = (.actions["source-custom"] | .enabled=false)' config/demo.json > "$UVP_CONFIG"
start_server
if [[ $transport == http ]]; then
    http_status 200 /
    grep -qi '<!doctype html>' "$temp/response" || die 'dashboard HTML missing'
    http_status 200 /style.css
    http_status 200 /api/info
    assert_json '.mode == "demo"'
    http_status 401 /api/state
    http_status 401 /api/state -H 'Authorization: Bearer incorrect'
    http_status 403 /api/state -H "Authorization: Bearer $UVP_TOKEN" -H 'Host: example.invalid'
    http_status 403 /api/state -H "Authorization: Bearer $UVP_TOKEN" -H 'Origin: https://example.invalid'
    http_status 403 /api/state -H "Authorization: Bearer $UVP_TOKEN" -H 'Sec-Fetch-Site: cross-site'
    http_status 415 /api/runs -H "Authorization: Bearer $UVP_TOKEN" -H 'Content-Type: text/plain' -d '{}'
    http_status 400 /api/runs -H "Authorization: Bearer $UVP_TOKEN" -H 'Content-Type: application/json' -d '{'
    echo 'PASS: browser assets, token, Host, Origin, request media type and JSON validation'
fi
request GET /api/config 200
assert_json '.mode == "demo" and .require_prepare and (.phases | length) == 5 and (.hosts.source | has("identity_file") | not)'
hosts='{"source":{"address":"192.0.2.10","user":"uvp","pid":0,"cntlid":1},"destination":{"address":"192.0.2.20","user":"uvp","pid":0,"cntlid":2}}'
for change in '.destination.address="10.0.0.555"' '.destination.user="-unsafe"' '.source.ssh_port=0' '.destination.controller="/dev/nvme0n1"' '.source.extra=true'; do
    request POST /api/hosts 400 "$(jq -c "$change" <<<"$hosts")"
done
request POST /api/hosts 200 "$hosts"
request POST /api/runs 409 '{"case":1}'
request POST /api/jobs 409 '{"job":"migrate"}'
request POST /api/jobs 400 '{"job":"unconfigured"}'
request POST /api/exec 404 '{"command":"true"}'
request POST /api/preflight 202 '{}'
await_state '.setup.status == "CHECKED"'
prepare
for invalid in '{"case":9}' '{"case":true}' '{"cntlid":1.5}' '{"hold_seconds":864000}' '{"automatic":"true"}' '{"host_action":"destination-custom"}' '{"host_action":"source-disabled"}' '{"case":5,"selectors":{"opcode":256}}' '{"case":5,"selectors":{"opcode":6,"cdw10_mask":4294967296}}' '{"case":5,"selectors":{"opcode":6,"queue":"all"}}' '{"host_action":"source-delete-ns","destructive_ack":"wrong"}'; do
    request POST /api/runs 400 "$invalid"
done
request POST /api/runs 409 '{"case":1,"pid":1999}'
request POST /api/runs 409 '{"case":3,"controller":"/dev/nvme77"}'
echo 'PASS: configuration, prerequisites, profiles, generic selectors and destructive action confirmation'
arm '{"case":1,"automatic":true,"auto_resume":true,"host_action":"source-custom","guest_action":"source-fio","hold_seconds":15}'
auto_rid=$rid
request POST /api/prepare 409 '{}'
request POST /api/hosts 409 "$hosts"
request POST /api/runs 409 '{"case":1}'
request POST "/api/runs/$rid/resume" 409 '{}'
request POST /api/runs/000000000000/cancel 409 '{}'
migrate
await_state '.run.status == "DONE" and .job.status == "DONE"'
assert_json '.run.host_action_status == "DONE" and .run.guest_action_status == "ACKNOWLEDGED" and .run.migration_result == "NOT VERIFIED"'
request POST /api/jobs 409 '{"job":"migrate"}'
request GET "/api/runs/$rid/export" 200
assert_json '(.events | length) > 5 and .run.automatic and ([.events[] | select(.message == "HOST_ACTION_STARTED")] | length) == 1'
echo 'PASS: one automatic action, release, separate migration result and event export'
prepare
arm '{"case":3,"automatic":false,"host_action":"destination-custom","hold_seconds":15}'
migrate
await_state '.run.status == "PAUSED"'
request POST "/api/runs/$rid/action" 200 '{}'
await_state '.run.status == "PAUSED" and .run.host_action_status == "DONE"'
request POST "/api/runs/$rid/action" 409 '{}'
request POST "/api/runs/$rid/resume" 200 '{}'
await_state '.run.status == "DONE"'
echo 'PASS: destination checkpoint, manual action exactly once, manual resume'
prepare
arm '{"case":5,"pid":12348,"target_host":"source","selectors":{"queue":"io","opcode":"0x02","nsid_mask":"0xffffffff"},"hold_seconds":15}'
cancel
prepare
arm '{"case":1,"host_action":"source-delete-ns","destructive_ack":"/dev/nvme0:1","automatic":true,"auto_resume":false,"hold_seconds":15}'
migrate
await_state '.run.status == "PAUSED" and .run.host_action_status == "DONE"'
cancel
request GET "/api/runs/$auto_rid/export" 200
assert_json '.run.status == "DONE"'
request GET /api/runs/000000000000/export 404
echo 'PASS: generic cancellation, exact acknowledgement and per-run history'
# Two simultaneous browser tabs must reserve exactly one checkpoint.
prepare
parallel_arm() (
    local slot=$1
    if [[ $transport == http ]]; then
        curl -sS --noproxy "*" --max-time 10 -o "$temp/race-$slot.body" -w "%{http_code}\n" \
            -H "Authorization: Bearer $UVP_TOKEN" -H "Content-Type: application/json" \
            --data-binary "{\"case\":1}" "$url/api/runs" >"$temp/race-$slot.code"
    else
        "$api" POST /api/runs <<<'{"case":1}' >"$temp/race-$slot.body"
        head -n1 "$temp/race-$slot.body" >"$temp/race-$slot.code"
    fi
)
parallel_arm 1 & first=$!
parallel_arm 2 & second=$!
wait "$first"; wait "$second"
[[ $(sort "$temp/race-1.code" "$temp/race-2.code") == $'201\n409' ]] || die "concurrent requests created zero or multiple runs"
await_state '.run.status == "ARMED"'
rid=$(jq -r .run.id "$temp/response")
cancel
echo 'PASS: concurrent arm requests reserve a single checkpoint'
# Simulate losing the controller after an ARMED run. The next session must
# archive the active run and must never reattach to its old helper process.
prepare
arm '{"case":2,"hold_seconds":15,"checkpoint_seconds":30}'
if [[ -n $server_pid ]]; then
    kill -KILL "$server_pid"
    wait "$server_pid" 2>/dev/null || :
    server_pid=
fi
api_initialized=false
start_server
request GET /api/state 200
jq -e --arg id "$rid" 'any(.history[]; .id==$id and .status=="INTERRUPTED")' "$temp/response" >/dev/null || die 'restart lost interrupted run'
request GET "/api/runs/$auto_rid/export" 200
assert_json '.run.status == "DONE"'
echo 'PASS: controller restart preserves records and interrupts orphaned checkpoints'
stop_server
bash tests/transport.sh
source tests/controller-hardware.inc.sh
bash tests/interactive-daemon.sh
bash tests/upgrade.sh
