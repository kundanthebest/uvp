#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Exercise real host action + daemon via fake SSH, with no remote execution.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"; touch "$tmp/key" "$tmp/known"
cat > "$tmp/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
cat <<STATUS
STATE=RUNNING
RUN_ID=mock-action
BOOT_ID=fake-boot
FIO_PID=123
START_TICKS=456
ORIGIN=event-tc${UVP_TESTCASE:-manual}
READ_BYTES=4096
WRITE_BYTES=8192
STATUS
MOCK
chmod +x "$tmp/bin/ssh"
cat > "$tmp/conf" <<CONF
RUN_ID=mock-action
OUTPUT_DIR="$tmp/results"
SSH_KEY="$tmp/key"
SSH_KNOWN_HOSTS="$tmp/known"
GUEST_USER=ubuntu
SOURCE_GUEST_HOST=mock
SOURCE_GUEST_PORT=2222
DEST_GUEST_HOST=mock
DEST_GUEST_PORT=2223
FIO_GUEST_SIDE=destination
GUEST_WAIT_SECONDS=3
CONF
mkdir -p "$tmp/results/mock-action"
printf "BOOT_ID=fake-boot\n" > "$tmp/results/mock-action/prepared.status"
PATH="$tmp/bin:$PATH" "${UVP_DAEMON:-$root/bin/uvp-daemon}" --selftest --case 2 -- \
    "$root/scripts/start-fio.sh" "$tmp/conf" > "$tmp/log" 2>&1
grep -q '^FIO_ACK:' "$tmp/log"
grep -q 'ACTION_ACKNOWLEDGED' "$tmp/log"
awk '/SIGCONT pid=/{released=1} /^FIO_REQUEST/{if(!released) exit 1}' "$tmp/log"
echo 'PASS: real host action queues after release and receives mocked guest acknowledgement'
# Bad guest endpoint/preparation is an action failure, not retry-success.
printf '#!/bin/sh\nexit 70\n' > "$tmp/bin/ssh"
if PATH="$tmp/bin:$PATH" "${UVP_DAEMON:-$root/bin/uvp-daemon}" --selftest --case 3 -- \
    "$root/scripts/start-fio.sh" "$tmp/conf" > "$tmp/fail" 2>&1; then
    echo 'FAIL: missing guest preparation accepted'; exit 1
fi
! grep -q ACTION_ACKNOWLEDGED "$tmp/fail"
echo 'PASS: missing guest run marker rejects launch'
