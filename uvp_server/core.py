# SPDX-License-Identifier: GPL-2.0-only
# Author: Kundan Kumar <kundan.kumar@samsung.com>
"""Local UVP coordinator. The C daemon alone owns QEMU stop/release."""
import copy
import ipaddress
import json
import os
import re
import shlex
import signal
import selectors
import sqlite3
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PHASES = {
    1: ('Suspend complete', 'source', 'nvmevf_cmd_suspend_device'),
    2: ('Get controller state complete', 'source', 'nvmevf_cmd_get_ctrl_state'),
    3: ('Set controller state complete', 'destination', 'nvmevf_cmd_set_ctrl_state'),
    4: ('Controller resume complete', 'destination', 'nvmevf_cmd_resume_device'),
    5: ('Custom NVMe command', 'source', ''),
}
ACTIVE = {'STARTING', 'ARMED', 'PAUSED', 'HOST_ACTION', 'RESUMING', 'RELEASED', 'CANCELLING'}

class RequestError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def integer(value, low, high, name):
    if isinstance(value, bool):
        raise RequestError(f'{name}: expected integer')
    try:
        if isinstance(value, str) and not re.fullmatch(r'(?:0x[0-9a-fA-F]+|[0-9]+)', value):
            raise ValueError()
        n = int(value, 0) if isinstance(value, str) and value.startswith('0x') else int(value)
        if isinstance(value, float) or not low <= n <= high:
            raise ValueError()
    except (ValueError, TypeError):
        raise RequestError(f'{name}: expected {low}..{high}') from None
    return n


def argv_valid(argv):
    if not isinstance(argv, list) or not argv or len(argv) > 64:
        raise RequestError('Configured command needs 1..64 argv elements')
    if not all(isinstance(x, str) and '\x00' not in x and '\n' not in x and len(x) < 4096 for x in argv):
        raise RequestError('Invalid configured argv')
    if not argv[0].startswith('/'):
        raise RequestError('Configured executable must have an absolute path')
    return argv


def host_command(host, argv):
    argv_valid(argv)
    if host.get('transport', 'local') == 'local':
        return argv
    if host.get('transport') != 'ssh':
        raise RequestError('Unknown host transport')
    target = host.get('ssh_target', '')
    if not re.fullmatch(r'[A-Za-z0-9_.@:\[\]-]+', target) or target.startswith('-'):
        raise RequestError('Invalid SSH target in server config')
    cmd = ['/usr/bin/ssh', '-T', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
           '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=3']
    if host.get('identity_file'):
        cmd += ['-i', host['identity_file']]
    if host.get('known_hosts_file'):
        cmd += ['-o', 'UserKnownHostsFile=' + host['known_hosts_file']]
    cmd += ['-p', str(integer(host.get('ssh_port', 22), 1, 65535, 'ssh_port')),
            target, shlex.join(argv)]
    return cmd


class Controller:
    def __init__(self, config, data_dir, demo=False):
        self.config = copy.deepcopy(config)
        self.demo = demo
        self.lock = threading.RLock()
        Path(data_dir).mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(str(Path(data_dir) / 'uvp.sqlite3'), check_same_thread=False)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.executescript('CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY, body TEXT);'
                             'CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY, run_id TEXT, time REAL, kind TEXT, message TEXT);')
        # Never reconnect a stale browser to an unowned PID/daemon after restart.
        for rid, body in self.db.execute('SELECT id,body FROM runs').fetchall():
            r = json.loads(body)
            if r['status'] in ACTIVE:
                r['status'] = 'INTERRUPTED'
                r['detail'] = 'Coordinator restarted; check daemon watchdog and actual VM state.'
                self.db.execute('UPDATE runs SET body=? WHERE id=?', (json.dumps(r), rid))
        self.db.commit()
        self.run = None
        self.proc = None
        self.job = None
        self.job_proc = None
        self.closing = False
        self.setup = {'status': 'IDLE', 'detail': 'Prepare destination, then source'}
        self.setup_proc = None
        self.data_dir = Path(data_dir)

    def event(self, kind, message):
        with self.lock:
            rid = self.run['id'] if self.run else 'system'
            self.db.execute('INSERT INTO events(run_id,time,kind,message) VALUES (?,?,?,?)',
                            (rid, time.time(), kind, str(message)[:8192]))
            self.db.commit()

    def save(self):
        if self.run:
            self.db.execute('INSERT OR REPLACE INTO runs VALUES (?,?)',
                            (self.run['id'], json.dumps(self.run)))
            self.db.commit()

    def public_config(self):
        with self.lock:
            return {'mode': 'demo' if self.demo else 'hardware',
                    'require_prepare': bool(self.config.get('require_prepare')),
                    'phases': [{'id': k, 'name': v[0], 'host': v[1], 'symbol': v[2]} for k, v in PHASES.items()],
                    'hosts': {k: {a: v.get(a) for a in ('transport', 'address', 'user', 'ssh_target', 'ssh_port', 'pid', 'controller', 'cntlid')} for k, v in self.config['hosts'].items()},
                    'actions': {k: {a: v.get(a) for a in ('label', 'kind', 'host', 'enabled', 'description', 'argv', 'destructive', 'confirmation', 'controller', 'nsid')} for k, v in self.config.get('actions', {}).items()},
                    'jobs': {k: {a: v.get(a) for a in ('label', 'kind', 'host', 'enabled')} for k, v in self.config.get('jobs', {}).items()}}

    def snapshot(self):
        with self.lock:
            rows = self.db.execute('SELECT seq,run_id,time,kind,message FROM events ORDER BY seq DESC LIMIT 250').fetchall()
            history = [json.loads(x[0]) for x in self.db.execute('SELECT body FROM runs ORDER BY rowid DESC LIMIT 30')]
            return {'mode': 'demo' if self.demo else 'hardware', 'run': copy.deepcopy(self.run),
                    'job': copy.deepcopy(self.job), 'setup': copy.deepcopy(self.setup), 'events': [dict(zip(('seq','run_id','time','kind','message'), x)) for x in reversed(rows)],
                    'history': history}

    def _idle(self):
        if self.closing or (self.run and self.run['status'] in ACTIVE) or (self.job and self.job['status'] == 'RUNNING') or self.setup['status'] in ('PREPARING', 'CHECKING'):
            raise RequestError('Wait for the active operation or disarm the checkpoint', 409)

    def update_hosts(self, data):
        with self.lock:
            self._idle()
            if set(data) != {'source', 'destination'}:
                raise RequestError('Supply source and destination host settings')
            updated = copy.deepcopy(self.config['hosts'])
            for side in ('source', 'destination'):
                v = data[side]
                if not isinstance(v, dict) or set(v) - {'address', 'user', 'ssh_port', 'pid', 'controller', 'cntlid'}:
                    raise RequestError('Unsupported host field')
                try: address = str(ipaddress.ip_address(v.get('address', '')))
                except ValueError: raise RequestError('Enter a literal Linux server IPv4 or IPv6 address') from None
                user = v.get('user', 'uvp')
                if not isinstance(user, str) or not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', user):
                    raise RequestError('Invalid SSH username')
                controller = v.get('controller', updated[side].get('controller', '/dev/nvme0'))
                if not isinstance(controller, str) or not re.fullmatch(r'/dev/nvme[0-9]+', controller):
                    raise RequestError('Invalid host NVMe controller')
                updated[side].update(address=address, user=user, ssh_target=user+'@'+address,
                    ssh_port=integer(v.get('ssh_port', 22), 1, 65535, 'SSH port'),
                    pid=integer(v.get('pid', 0), 0, 2**31-1, 'PID'), controller=controller,
                    cntlid=integer(v.get('cntlid', 1), 0, 65535, 'CNTLID'))
                if not self.demo: updated[side]['transport'] = 'ssh'
            self.config['hosts'] = updated
            self.setup = {'status': 'IDLE', 'detail': 'Host settings changed; prepare hosts again'}
            self.event('config', 'Updated source and destination connections for this server session')
            return self.public_config()

    def _bridge(self, side, verb, payload=None):
        host = self.config['hosts'][side]
        if self.demo:
            time.sleep(.15)
            return {'ok': True, 'role': side, 'pid': 12345 if side == 'source' else 23456,
                    'controller': host['controller'], 'cntlid': host['cntlid'],
                    'qmp_status': 'running' if side == 'source' else 'inmigrate', 'simulated': True}
        argv = host.get('privilege_prefix', []) + ['/usr/bin/python3', host.get('bridge', '/opt/uvp-orchestrator/scripts/host-bridge.py'), verb]
        request = {'role': side, **(payload or {})}
        proc = subprocess.Popen(host_command(host, argv), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        with self.lock:
            self.setup_proc = proc
            if self.closing: proc.terminate()
        try:
            stdout, stderr = proc.communicate(json.dumps(request).encode(), timeout=180)
        except subprocess.TimeoutExpired:
            proc.kill(); proc.communicate()
            raise RequestError(side+' host operation timed out; inspect remote host', 504) from None
        finally:
            with self.lock: self.setup_proc = None
        if proc.returncode:
            raise RequestError(side+' '+verb+' failed: '+(stderr or stdout).decode('utf-8', 'replace')[-3000:])
        try: result = json.loads(stdout)
        except ValueError: raise RequestError(side+' bridge did not return JSON') from None
        if not isinstance(result, dict) or result.get('ok') is not True or result.get('role') != side:
            raise RequestError(side+' bridge did not confirm the requested operation')
        return result

    def setup_hosts(self, verb='prepare'):
        if verb not in ('prepare', 'preflight'): raise RequestError('Invalid setup operation')
        with self.lock:
            self._idle()
            self.setup = {'status': 'PREPARING' if verb == 'prepare' else 'CHECKING', 'detail': 'Checking destination first', 'hosts': {}}
            threading.Thread(target=self._setup_worker, args=(verb,), daemon=True).start()
            return copy.deepcopy(self.setup)

    def _setup_worker(self, verb):
        try:
            for side in ('destination', 'source'):
                with self.lock:
                    if self.closing: raise RequestError('Coordinator is shutting down')
                    self.setup['detail'] = verb+' '+side
                result = self._bridge(side, verb)
                with self.lock:
                    self.setup['hosts'][side] = result
                    if verb == 'prepare':
                        pid = integer(result.get('pid'), 2, 2**31-1, 'Verified QEMU PID')
                        if result.get('controller') != self.config['hosts'][side]['controller'] or integer(result.get('cntlid'), 0, 65535, 'Host CNTLID') != self.config['hosts'][side]['cntlid']:
                            raise RequestError(side+' device settings differ from /etc/uvp/host.json; align UI and host config')
                        expected = 'running' if side == 'source' else 'inmigrate'
                        if result.get('qmp_status') != expected:
                            raise RequestError(side+' QEMU must report '+expected)
                        self.config['hosts'][side]['pid'] = pid
                    self.event('setup', side+' '+verb+' confirmed'+(' (simulation)' if self.demo else ''))
            with self.lock:
                self.setup.update(status='READY' if verb == 'prepare' else 'CHECKED', detail='Both hosts prepared' if verb == 'prepare' else 'Preflight complete; prepare hosts next')
        except Exception as exc:
            with self.lock:
                self.setup.update(status='FAILED', detail=str(exc))
                self.event('error', str(exc))

    def profile(self, key, kind, host=None):
        if not key or key == 'none':
            return None
        p = self.config.get('actions', {}).get(key)
        if not p or not p.get('enabled') or p.get('kind') != kind:
            raise RequestError('Action is missing, disabled, or of the wrong kind')
        if host and p.get('host') != host:
            raise RequestError('Action must execute on the checkpoint daemon host; choose its matching profile')
        argv_valid(p['argv'])
        return p

    def arm(self, data):
        with self.lock:
            if self.closing:
                raise RequestError('Server is shutting down', 409)
            if self.run and self.run['status'] in ACTIVE:
                raise RequestError('A checkpoint is already active', 409)
            if self.job and self.job['status'] == 'RUNNING':
                raise RequestError('Wait for the current setup job', 409)
            if self.setup['status'] in ('PREPARING', 'CHECKING'):
                raise RequestError('Wait for host preparation', 409)
            if self.config.get('require_prepare') and self.setup['status'] != 'READY':
                raise RequestError('Prepare both hosts before loading hooks', 409)
            case = integer(data.get('case', 1), 1, 5, 'case')
            phase, side, default_symbol = PHASES[case]
            selectors_data = {}
            if case == 5:
                side = data.get('target_host', 'source')
                if side not in ('source', 'destination'): raise RequestError('Invalid trigger host')
                s = data.get('selectors', {})
                if not isinstance(s, dict): raise RequestError('Selectors must be an object')
                selectors_data['opcode'] = integer(s.get('opcode'), 0, 255, 'opcode')
                if s.get('queue', 'admin') not in ('admin', 'io'): raise RequestError('Queue must be admin or io')
                selectors_data['queue'] = s.get('queue', 'admin')
                for field in ('nsid', 'nsid_mask', 'cdw10', 'cdw10_mask', 'cdw11', 'cdw11_mask'):
                    selectors_data[field] = integer(s.get(field, 0), 0, 0xffffffff, field)
            automatic = data.get('automatic', False)
            auto_resume = data.get('auto_resume', True)
            if not isinstance(automatic, bool) or not isinstance(auto_resume, bool):
                raise RequestError('Automatic action and resume must be booleans')
            host = self.config['hosts'][side]
            pid = integer(data.get('pid', host.get('pid', 0)), 2, 2**31-1, 'QEMU TGID')
            if self.config.get('require_prepare') and case != 5 and pid != host.get('pid'):
                raise RequestError('Migration hook PID must match the QEMU PID verified by Prepare hosts', 409)
            controller = data.get('controller', host.get('controller', ''))
            if not isinstance(controller, str) or not re.fullmatch(r'/dev/nvme[0-9]+', controller):
                raise RequestError('Use a host controller such as /dev/nvme0, not a namespace')
            cntlid = integer(data.get('cntlid', host.get('cntlid', 1)), 0, 65535, 'CNTLID')
            if self.config.get('require_prepare') and case != 5 and (controller != host.get('controller') or cntlid != host.get('cntlid')):
                raise RequestError('Save controller/CNTLID settings and prepare hosts before changing the migration hook target', 409)
            hold = integer(data.get('hold_seconds', 120), 5, 600, 'hold_seconds')
            timeout = integer(data.get('checkpoint_seconds', 300), 5, 86400, 'checkpoint_seconds')
            host_key, guest_key = data.get('host_action', 'none'), data.get('guest_action', 'none')
            hp = self.profile(host_key, 'host', side)
            gp = self.profile(guest_key, 'guest', side)
            if hp and hp.get('destructive'):
                confirmation = hp.get('confirmation') or str(hp.get('controller', controller))+':'+str(hp.get('nsid', ''))
                if data.get('destructive_ack') != confirmation:
                    raise RequestError('Confirm the exact destructive action target: '+confirmation)
            symbol = host.get('symbols', {}).get(str(case), default_symbol)
            if (symbol or case != 5) and not re.fullmatch(r'[A-Za-z0-9_.$]+', symbol):
                raise RequestError('Invalid configured wrapper symbol')
            daemon = host.get('daemon', '')
            args = [daemon, '--pid', str(pid), '--case', str(case), '--controller', controller,
                    '--cntlid', str(cntlid), '--bpf', host.get('bpf', ''),
                    '--timeout', str(timeout), '--control-stdin', '--hold-timeout', str(hold),
                    '--action-timeout', str(integer(self.config.get('action_timeout', 300), 1, 86400, 'action_timeout'))]
            if symbol: args += ['--phase-symbol', symbol]
            if case == 5:
                for field, value in selectors_data.items():
                    args += ['--'+field.replace('_', '-'), str(value)]
            if hp:
                args += ['--host-action-program', hp['argv'][0]]
                for arg in hp['argv'][1:]:
                    args += ['--host-action-arg', arg]
            args += ['--'] + (gp['argv'] if gp else ['/bin/true'])
            if self.demo:
                args = [sys.executable, '-u', str(ROOT/'uvp_server'/'simulator.py'), '--case', str(case),
                        '--hold', str(hold), '--host-action', host_key, '--guest-action', guest_key]
            else:
                prefix = host.get('privilege_prefix', [])
                if prefix:
                    argv_valid(prefix)
                args = host_command(host, prefix + args)
            self.run = {'id': uuid.uuid4().hex[:12], 'status': 'STARTING', 'case': case, 'phase': phase,
                        'host': side, 'pid': pid, 'controller': controller, 'cntlid': cntlid,
                        'symbol': symbol, 'hold_seconds': hold, 'checkpoint_seconds': timeout,
                        'host_action': host_key, 'guest_action': guest_key,
                        'automatic': automatic, 'auto_resume': auto_resume, 'selectors': selectors_data,
                        'auto_action_requested': False, 'auto_resume_requested': False,
                        'host_action_status': 'READY' if hp else 'NONE',
                        'guest_action_status': 'QUEUED' if gp else 'NONE',
                        'created_at': time.time(), 'hold_deadline': None, 'detail': 'Starting checkpoint daemon',
                        'demo': self.demo, 'migration_started': False, 'migration_script_status': 'NOT STARTED', 'migration_result': 'NOT VERIFIED',
                        'hosts': copy.deepcopy(self.public_config()['hosts'])}
            self.save()
            self.event('run', 'Starting ' + ('simulated' if self.demo else 'hardware') + ' checkpoint run')
            try:
                self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                             stderr=subprocess.PIPE, start_new_session=True, bufsize=0)
            except OSError as e:
                self.run.update(status='FAILED', detail=str(e))
                self.save()
                self.event('error', str(e))
                raise RequestError(f'Cannot start daemon: {e}', 500) from None
            proc, rid = self.proc, self.run['id']
            threading.Thread(target=self._monitor, args=(proc,rid), daemon=True).start()
            return copy.deepcopy(self.run)

    def _line(self, line):
        # Only the daemon's control stdout is parsed. Child action stdout is
        # redirected to stderr by the daemon; ordinary action output cannot
        # spoof READY, HOLD_READY or HOST_ACTION_DONE control events.
        self.event('daemon', line)
        r = self.run
        if r['status'] == 'CANCELLING':
            return
        if line.startswith('READY '):
            r.update(status='ARMED', detail='Hooks attached; start migration when ready')
        elif line.startswith('HOLD_READY '):
            r.update(status='PAUSED', hold_deadline=time.time()+r['hold_seconds'], detail='Owned QEMU stop confirmed')
        elif line == 'HOST_ACTION_STARTED':
            r.update(status='HOST_ACTION', host_action_status='RUNNING')
        elif line == 'HOST_ACTION_DONE':
            r.update(status='PAUSED', host_action_status='DONE', detail='Host action completed; checkpoint remains held')
        elif line.startswith('HOST_ACTION_FAILED'):
            r.update(host_action_status='FAILED', detail='Host action failed; daemon cleanup releases its target')
        elif line.startswith('SIGCONT pid='):
            r.update(status='RELEASED', hold_deadline=None, detail='QEMU released; guest runstate is not inferred')
        elif line.startswith('ACTION_EXEC:') and r['guest_action'] != 'none':
            r['guest_action_status'] = 'WAITING FOR ACK'
        elif line.startswith('ACTION_ACKNOWLEDGED:'):
            r['guest_action_status'] = 'ACKNOWLEDGED' if r['guest_action'] != 'none' else 'NONE'
        elif line.startswith(('FAIL:', 'WATCHDOG:', 'RUN_FAILED', 'CLEANUP:')):
            r['detail'] = line
        self.save()
        self._drive_automatic()

    def _drive_automatic(self):
        r = self.run
        if not r or not r.get('automatic') or r['status'] != 'PAUSED': return
        try:
            if r['host_action_status'] == 'READY' and not r.get('auto_action_requested'):
                r['auto_action_requested'] = True
                self.control(r['id'], 'action')
            elif r['host_action_status'] in ('NONE', 'DONE') and r.get('auto_resume') and not r.get('auto_resume_requested'):
                r['auto_resume_requested'] = True
                self.control(r['id'], 'resume')
        except RequestError as exc:
            r['automatic'] = False
            r['detail'] = 'Automatic control stopped: '+str(exc)
            self.event('error', r['detail'])
            self.save()

    def _stderr(self, proc, rid):
        for raw in iter(lambda: proc.stderr.readline(8192), b''):
            line=raw.decode('utf-8','replace').rstrip()
            with self.lock:
                if self.run and self.run['id']==rid:
                    self.event('daemon-stderr',line)
                    if line.startswith(('FAIL:', 'WATCHDOG:', 'RUN_FAILED', 'CLEANUP:')):
                        self.run['detail']=line
                        self.save()

    def _monitor(self, proc, rid):
        err_thread=threading.Thread(target=self._stderr,args=(proc,rid),daemon=True)
        err_thread.start()
        try:
            while True:
                raw = proc.stdout.readline(8192)
                if not raw:
                    break
                line = raw.decode('utf-8', 'replace').rstrip()
                with self.lock:
                    if self.run and self.run['id'] == rid:
                        self._line(line)
            rc = proc.wait()
            err_thread.join(2)
        except Exception as e:
            with self.lock:
                self.event('error', f'Daemon stream error: {e}')
            rc = -1
        finally:
            for pipe in (proc.stdin, proc.stdout, proc.stderr):
                try: pipe.close()
                except (OSError, AttributeError): pass
        with self.lock:
            if not self.run or self.run['id'] != rid:
                return
            was_cancelled = self.run['status'] == 'CANCELLING'
            # rc=0 means checkpoint/action cycle finished, never migration PASS.
            self.run.update(status='CANCELLED' if was_cancelled else ('DONE' if rc==0 else 'FAILED'),
                            returncode=rc, ended_at=time.time(), hold_deadline=None)
            if rc != 0 and self.run['host_action_status'] == 'RUNNING':
                self.run['host_action_status'] = 'FAILED / CHECK TARGET'
            if rc == 0:
                self.run['detail'] = 'Checkpoint cycle complete. Verify migration and fio separately.'
            self.event('exit', f'Daemon exited rc={rc}; migration outcome remains unverified')
            self.save()
            self.proc = None

    def control(self, rid, command):
        with self.lock:
            r = self.run
            if not r or r['id'] != rid:
                raise RequestError('Stale run ID', 409)
            if not self.proc or self.proc.poll() is not None:
                raise RequestError('Daemon is not running', 409)
            if command == 'resume':
                if r['status'] != 'PAUSED':
                    raise RequestError('Resume requires a held, idle checkpoint', 409)
                r['status'] = 'RESUMING'
            elif command == 'action':
                if r['status'] != 'PAUSED' or r['host_action_status'] != 'READY':
                    raise RequestError('Host action requires a hold and an unused configured action', 409)
                r.update(status='HOST_ACTION', host_action_status='RUNNING')
            elif command == 'cancel':
                if r['status'] not in ACTIVE:
                    raise RequestError('Run is no longer active', 409)
                r.update(status='CANCELLING', detail='Cancelling checkpoint; migration itself is not cancelled')
            else:
                raise RequestError('Unknown control')
            try:
                self.proc.stdin.write((command+'\n').encode())
                self.proc.stdin.flush()
            except (OSError, ValueError):
                raise RequestError('Control channel closed; waiting for daemon exit', 409) from None
            self.event('operator', command)
            self.save()
            return copy.deepcopy(r)

    def launch_job(self, key):
        with self.lock:
            if self.closing or self.setup['status'] in ('PREPARING', 'CHECKING'):
                raise RequestError('Wait for host preparation', 409)
            p = self.config.get('jobs', {}).get(key)
            if not p or not p.get('enabled'):
                raise RequestError('Job is missing or disabled')
            if self.job and self.job['status'] == 'RUNNING':
                raise RequestError('A setup/job command is already running', 409)
            if p.get('kind') == 'migration':
                if not self.run or self.run['status'] != 'ARMED' or self.run.get('migration_started'):
                    raise RequestError('Migration requires an ARMED checkpoint and can be requested once per run', 409)
            elif self.run and self.run['status'] in ACTIVE:
                raise RequestError('Setup/prepare/result jobs require no active checkpoint', 409)
            argv_valid(p['argv'])
            host = self.config['hosts'][p['host']]
            prefix = host.get('privilege_prefix', []) if p.get('use_privilege') else []
            cmd = host_command(host, prefix+p['argv'])
            bridge_input = None
            if p.get('bridge_verb') == 'migrate':
                destination = self.config['hosts']['destination'].get('address', '')
                try: destination = str(ipaddress.ip_address(destination))
                except ValueError: raise RequestError('Save the destination IP first') from None
                bridge_input = json.dumps({'role': 'source', 'destination_ip': destination,
                                           'expected_pid': self.config['hosts']['source'].get('pid')}).encode()
            if self.demo:
                cmd = [sys.executable, '-c', 'print("SIMULATION: configured job completed; no hardware action")']
            self.job = {'id': uuid.uuid4().hex[:12], 'key': key, 'label': p['label'], 'status': 'RUNNING'}
            try:
                proc = subprocess.Popen(cmd, stdin=subprocess.PIPE if bridge_input and not self.demo else subprocess.DEVNULL, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, start_new_session=True)
            except OSError as e:
                self.job.update(status='FAILED', detail=str(e))
                raise RequestError(str(e), 500) from None
            self.job_proc = proc
            if bridge_input and not self.demo:
                try:
                    proc.stdin.write(bridge_input); proc.stdin.close()
                except (OSError, ValueError):
                    proc.terminate()
                    self.job.update(status='FAILED', detail='Migration bridge input failed')
                    self.job_proc = None
                    raise RequestError('Migration bridge input failed', 500) from None
            if p.get('kind') == 'migration':
                self.run['migration_started'] = True
                self.run['migration_script_status'] = 'RUNNING'
                if self.config.get('require_prepare'):
                    self.setup = {'status': 'CONSUMED', 'detail': 'This host preparation belongs to the current migration; prepare again before another run'}
                self.save()
            self.event('job', 'Started '+p['label'])
            threading.Thread(target=self._job_monitor, args=(proc,p.get('timeout',300),self.job['id'],self.run['id'] if self.run else None,p.get('kind')), daemon=True).start()
            if self.demo and p.get('kind') == 'migration':
                self.proc.stdin.write(b'trigger\n')
                self.proc.stdin.flush()
            return copy.deepcopy(self.job)

    def _job_monitor(self, proc, timeout, job_id=None, run_id=None, kind=None):
        # Bound reads and command lifetime, even if a misconfigured descendant
        # retains stdout. Terminate only the launched script/SSH client, not a
        # QEMU child that an operator's setup script may have started.
        deadline=time.monotonic()+float(timeout)
        expired=False
        terminate_at=None
        pending=b''
        selector=selectors.DefaultSelector()
        os.set_blocking(proc.stdout.fileno(),False)
        selector.register(proc.stdout,selectors.EVENT_READ)
        def output(raw):
            self.event('job-output',raw.decode('utf-8','replace').rstrip())
        try:
            while True:
                now=time.monotonic()
                if proc.poll() is None and now>=deadline and not expired:
                    expired=True
                    proc.terminate()
                    terminate_at=now
                if terminate_at is not None and proc.poll() is None and now-terminate_at>1:
                    proc.kill()
                ready=selector.select(.05)
                if ready:
                    for _ in range(16):
                        try: raw=os.read(proc.stdout.fileno(),8192)
                        except BlockingIOError: break
                        if not raw: break
                        pending+=raw
                        while b'\n' in pending:
                            line,pending=pending.split(b'\n',1)
                            output(line)
                        if len(pending)>=8192:
                            output(pending[:8192]);pending=pending[8192:]
                if proc.poll() is not None:
                    # One bounded final drain; do not wait for background children.
                    for _ in range(16):
                        try: raw=os.read(proc.stdout.fileno(),8192)
                        except BlockingIOError: break
                        if not raw: break
                        pending+=raw
                        while b'\n' in pending:
                            line,pending=pending.split(b'\n',1)
                            output(line)
                        if len(pending)>=8192:
                            output(pending[:8192]);pending=pending[8192:]
                    break
            if pending: output(pending)
            rc=proc.wait()
        finally:
            selector.close()
            proc.stdout.close()
        with self.lock:
            if job_id and self.job['id'] != job_id: return
            self.job.update(status='TIMEOUT' if expired else ('DONE' if rc==0 else 'FAILED'), returncode=rc)
            if kind == 'migration' and self.run and self.run['id'] == run_id:
                self.run['migration_script_status'] = 'SIMULATED' if self.demo and not expired and rc==0 else self.job['status']
                self.run['migration_script_returncode'] = rc
                self.save()
            self.event('job', 'Job exited '+str(rc)+'; remote/guest effects require independent verification')
            self.job_proc = None

    def export(self, rid):
        with self.lock:
            row = self.db.execute('SELECT body FROM runs WHERE id=?',(rid,)).fetchone()
            if not row: raise RequestError('Unknown run',404)
            rows = self.db.execute('SELECT seq,time,kind,message FROM events WHERE run_id=? ORDER BY seq',(rid,)).fetchall()
            return {'run':json.loads(row[0]), 'events':[dict(zip(('seq','time','kind','message'),v)) for v in rows]}

    def close(self):
        with self.lock:
            self.closing = True
            p = self.proc
            if p:
                try:
                    p.stdin.write(b'cancel\n'); p.stdin.flush(); p.stdin.close()
                except (OSError, ValueError): pass
            j = self.job_proc
            if j:
                try: j.terminate()
                except ProcessLookupError: pass
            if self.setup_proc:
                try: self.setup_proc.terminate()
                except ProcessLookupError: pass
        if p:
            try: p.wait(timeout=8)
            except subprocess.TimeoutExpired:
                # Kill only transport/daemon, never QEMU. Daemon watchdog owns release.
                try: p.kill()
                except ProcessLookupError: pass
        # SQLite is left open until process exit; background readers may still flush.
