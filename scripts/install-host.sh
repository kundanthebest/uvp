#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
ROLE=''
INSTALL_DEPS=false
while (($#)); do
    case "$1" in
        --role) [[ $# -ge 2 ]] || { echo '--role needs source or destination' >&2; exit 2; }; ROLE=$2; shift 2 ;;
        --install-deps) INSTALL_DEPS=true; shift ;;
        *) echo 'Usage: sudo ./scripts/install-host.sh --role source|destination [--install-deps]' >&2; exit 2 ;;
    esac
done
[[ $ROLE == source || $ROLE == destination ]] || { echo '--role source|destination is required' >&2; exit 2; }
[[ $EUID == 0 ]] || { echo 'Run this installer with sudo on the intended lab Linux host' >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo 'The current BPF implementation supports x86-64 hosts' >&2; exit 1; }
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET=/opt/uvp-orchestrator
if $INSTALL_DEPS; then
    command -v apt-get >/dev/null || { echo '--install-deps supports Debian/Ubuntu; install dependencies manually on other distributions' >&2; exit 1; }
    apt-get update
    apt-get install -y build-essential clang llvm pkg-config libbpf-dev libelf-dev zlib1g-dev python3 openssh-client nvme-cli jq socat
fi
[[ ! -L $TARGET ]] || { echo 'Install target must not be a symlink' >&2; exit 1; }
install -d -o root -g root -m 0755 "$TARGET" /etc/uvp
install -d -o root -g root -m 0750 /var/log/uvp /run/uvp-hmlm
/usr/bin/python3 - "$PROJECT_DIR" "$TARGET" <<'PY'
import os, shutil, sys
from pathlib import Path
source, target = map(Path, sys.argv[1:])
excluded = {'.git', 'var', 'build', '__pycache__', 'hardware.json', 'uvp.conf', 'host.json', 'ui-hosts.json'}
for path in source.rglob('*'):
    relative = path.relative_to(source)
    if any(part in excluded for part in relative.parts) or path.suffix in ('.pyc', '.sqlite3', '.pem', '.key'):
        continue
    if path.is_symlink():
        raise SystemExit('Unexpected symlink in project package: ' + str(relative))
    dest = target / relative
    if dest.is_symlink():
        raise SystemExit('Unexpected symlink in installation: ' + str(dest))
    if path.is_dir():
        dest.mkdir(exist_ok=True)
        dest.chmod(0o755)
    else:
        if source != target:
            shutil.copyfile(path, dest)
        dest.chmod(0o755 if path.suffix in ('.sh', '.py') or path.name == 'uvp-daemon' else 0o644)
    os.chown(dest, 0, 0)
PY
make -C "$TARGET" build CLANG=/usr/bin/clang
if [[ ! -e /etc/uvp/host.json ]]; then
    install -m 0600 "$TARGET/config/host-${ROLE}.example.json" /etc/uvp/host.json
    echo 'Created /etc/uvp/host.json from the example; configure the real launcher, QEMU path, QMP socket and pidfile before use.'
else
    echo 'Preserved existing /etc/uvp/host.json; confirm its role and paths manually.'
fi
echo "Installed UVP host tools in $TARGET. No VM, eBPF program, reset or migration was started."
echo 'Next: edit /etc/uvp/host.json, then run sudo /opt/uvp-orchestrator/scripts/host-preflight.py </dev/null'
