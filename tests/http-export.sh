#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# A large append-only journal must remain downloadable from either interface.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
temp=$(mktemp -d)
pid=
cleanup() {
    if [[ -n $pid ]]; then
        kill "$pid" 2>/dev/null || :
        wait "$pid" 2>/dev/null || :
    fi
    rm -rf -- "$temp"
}
trap cleanup EXIT
UVP_TOKEN=uvp-demo "${1:-$root/build/uvp-controller}" --root "$root" \
    --config "$root/config/demo.json" --data-dir "$temp/state" --port 0 > "$temp/server.log" 2>&1 &
pid=$!
url=
for ((i=0; i<160; i++)); do
    url=$(sed -n 's/^UVP DEMO \(http:.*\)$/\1/p' "$temp/server.log")
    [[ -z $url ]] || break
    kill -0 "$pid" 2>/dev/null || break
    sleep .05
done
if [[ -z $url ]]; then
    cat "$temp/server.log" >&2
    if [[ -z ${GITHUB_ACTIONS:-} ]] && grep -Eq '^(bind|socket): (Permission denied|Operation not permitted)' "$temp/server.log"; then
        echo 'SKIP: this environment prohibits loopback HTTP'
        exit 0
    fi
    exit 1
fi

id=abcdef123456
echo '{"id":"abcdef123456","status":"DONE"}' > "$temp/state/runs/$id.json"
awk 'BEGIN {
  for (n = 0; n < 7000; n++) message = message "x"
  for (i = 1; i <= 800; i++) printf "{\"seq\":%d,\"message\":\"%s\"}\n", i, message
}' > "$temp/state/runs/$id.events"
curl_base=(curl --noproxy '*' --silent --show-error --fail --max-time 45)
"${curl_base[@]}" -H 'Authorization: Bearer uvp-demo' "$url/api/runs/$id/export" > "$temp/api.json"
"${curl_base[@]}" -u uvp:uvp-demo -H "Origin: $url" -d "id=$id" "$url/forms/export" > "$temp/forms.json"

[[ $(wc -c < "$temp/api.json") -gt 4194304 ]]
jq -e --arg id "$id" '.run.id == $id and (.events | length == 800)
    and .events[0].seq == 1 and .events[-1].seq == 800
    and all(.events[]; (.message | length) == 7000)' "$temp/api.json" >/dev/null
cmp "$temp/api.json" "$temp/forms.json"
echo 'PASS: both export endpoints returned the complete 5.6 MB journal'
