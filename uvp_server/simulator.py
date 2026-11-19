# SPDX-License-Identifier: GPL-2.0-only
"""Explicit UI simulator. Never signals a process or executes a workload."""
import argparse
import select
import sys
import time
p=argparse.ArgumentParser()
p.add_argument('--case',type=int,default=1)
p.add_argument('--hold',type=int,default=120)
p.add_argument('--host-action',default='none')
p.add_argument('--guest-action',default='none')
a=p.parse_args()
print('SIMULATED: no BPF, QEMU, device reset or guest fio',flush=True)
print(f'READY pid=12345 case={a.case} phase=demo',flush=True)
held=False
host_ran=False
deadline=time.monotonic()+300
while time.monotonic()<deadline:
    r,_,_=select.select([sys.stdin],[],[],.1)
    if not r: continue
    cmd=sys.stdin.readline().strip()
    if cmd in ('','cancel'):
        print('CLEANUP: simulated release',flush=True)
        sys.exit(1)
    if cmd=='trigger' and not held:
        print('EVENT simulated=1 status=0 later_mask=0 wrapper_rc=0',flush=True)
        print('STOP_CONFIRMED pid=12345 simulated=1',flush=True)
        print(f'HOLD_READY timeout_s={a.hold}',flush=True)
        held=True
        deadline=time.monotonic()+a.hold
    elif cmd=='action' and held and not host_ran and a.host_action!='none':
        host_ran=True
        print('HOST_ACTION_STARTED',flush=True)
        print('SIMULATED: host action '+a.host_action,flush=True)
        time.sleep(.5)
        print('HOST_ACTION_DONE',flush=True)
    elif cmd=='resume' and held:
        print('SIGCONT pid=12345 simulated=1',flush=True)
        if a.guest_action!='none':
            print('ACTION_EXEC: simulated guest readiness',flush=True)
        time.sleep(.2)
        print('ACTION_ACKNOWLEDGED: simulation only; no migration PASS',flush=True)
        sys.exit(0)
    else:
        print('CONTROL_REJECTED: invalid state or command',flush=True)
print('FAIL: simulated checkpoint/hold deadline',flush=True)
sys.exit(1)
