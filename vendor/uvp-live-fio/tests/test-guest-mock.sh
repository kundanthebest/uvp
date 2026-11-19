#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# No disk IO workload, SSH, NVMe or VM. Fake fio exercises exactly-once launcher.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export UVP_GUEST_BASE="$tmp/guest"
id=mock-001
dir="$UVP_GUEST_BASE/$id"
mkdir -p "$dir" "$tmp/storage"
cp "$root/guest/guest-fio.sh" "$dir/"
echo "$id" > "$dir/prepared"
cat > "$tmp/fake-fio" <<'MOCK'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then echo fio-999; exit 0; fi
echo started >> "$MOCK_COUNT"
sleep 1
exit 0
MOCK
chmod +x "$tmp/fake-fio"
export MOCK_COUNT="$tmp/count"
cat > "$dir/settings" <<SETTINGS
FIO_DIR="$tmp/storage"
FIO_SIZE_MB=1
FIO_RUNTIME_SECONDS=2
FIO_IODEPTH=1
FIO_ENGINE=libaio
FIO_BINARY="$tmp/fake-fio"
UVP_MOCK_ONLY=1
SETTINGS
"$dir/guest-fio.sh" start "$id" event-tc1 >/dev/null
"$dir/guest-fio.sh" start "$id" event-tc1 >/dev/null
for _ in {1..100}; do [[ -f $dir/exit-code ]] && break; sleep .03; done
[[ $(cat "$dir/exit-code") == 0 ]]
[[ $(wc -l < "$tmp/count") == 1 ]]
"$dir/guest-fio.sh" start "$id" event-tc1 > "$tmp/status"
grep -q '^STATE=DONE$' "$tmp/status"
[[ $(wc -l < "$tmp/count") == 1 ]]
echo 'PASS: duplicate/lost-ack retries cannot create a second fake fio process'
# Separate run fails, and guest status preserves that failure.
id=mock-002; dir="$UVP_GUEST_BASE/$id"; mkdir "$dir"
cp "$UVP_GUEST_BASE/mock-001/"{settings,guest-fio.sh} "$dir/"
echo "$id" > "$dir/prepared"
sed -i 's/exit 0$/exit 7/' "$tmp/fake-fio" # version invocation exits early 0
"$dir/guest-fio.sh" start "$id" event-tc2 >/dev/null
for _ in {1..100}; do [[ -f $dir/exit-code ]] && break; sleep .03; done
[[ $(cat "$dir/exit-code") == 7 ]]
echo 'PASS: fake fio failure is recorded, not called success'
