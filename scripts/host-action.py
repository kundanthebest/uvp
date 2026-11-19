#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Author: Kundan Kumar <kundan.kumar@samsung.com>
"""Explicit configured host operations. No arbitrary browser-provided command."""
import argparse
import os
import re
import shutil
import subprocess
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['nvme-reset', 'vf-flr', 'namespace-delete'])
    p.add_argument('target')
    p.add_argument('--nsid', type=int)
    a = p.parse_args()
    if os.geteuid() != 0:
        p.error('Host actions require root')
    if a.action in ('nvme-reset', 'namespace-delete'):
        if not re.fullmatch(r'/dev/nvme[0-9]+', a.target):
            p.error('Expected controller /dev/nvmeN')
        if not Path(a.target).is_char_device():
            p.error('Controller character device missing')
        exe = shutil.which('nvme')
        if not exe:
            p.error('nvme-cli is not installed')
        if a.action == 'nvme-reset':
            if a.nsid is not None:
                p.error('--nsid applies only to namespace-delete')
            argv = [exe, 'reset', a.target]
        else:
            if a.nsid is None or not 1 <= a.nsid <= 0xfffffffe:
                p.error('namespace-delete requires one explicit NSID (1..0xfffffffe); all namespaces is refused')
            argv = [exe, 'delete-ns', a.target, '--namespace-id=' + str(a.nsid)]
        print('Executing ' + a.action + ' on ' + a.target + (':' + str(a.nsid) if a.nsid else ''), flush=True)
        return subprocess.call(argv, stdin=subprocess.DEVNULL)
    if a.nsid is not None:
        p.error('--nsid applies only to namespace-delete')
    if not re.fullmatch(r'[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]', a.target):
        p.error('Expected full PCI BDF, e.g. 0000:83:00.1')
    d = Path('/sys/bus/pci/devices') / a.target
    if not (d / 'physfn').is_symlink():
        p.error('Target is not a VF; refusing PF reset')
    m = d / 'reset_method'
    if not m.exists() or 'flr' not in m.read_text().split():
        p.error('Kernel does not expose FLR for this VF')
    original = m.read_text().strip()
    try:
        m.write_text('flr\n')
        if m.read_text().strip() != 'flr':
            p.error('Could not restrict reset method to FLR')
        print('Requesting VF FLR on ' + a.target, flush=True)
        (d / 'reset').write_text('1\n')
    finally:
        if m.exists():
            m.write_text(original + '\n')
    print('Host reset request completed; verify device and VM recovery independently')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
