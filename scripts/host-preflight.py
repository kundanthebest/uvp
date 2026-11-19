#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Read-only host prerequisite and VM state checks; requires root for consistency."""
from pathlib import Path
import subprocess
raise SystemExit(subprocess.run(['/usr/bin/python3', str(Path(__file__).with_name('host-bridge.py')), 'preflight'], input=b'{}').returncode)
