#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Author: Kundan Kumar <kundan.kumar@samsung.com>
"""Fixed SSH entry point; executable commands come only from root-owned host config."""
import argparse
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import socket
import struct
import subprocess
import sys
import time

CONFIG = Path('/etc/uvp/host.json')


def trusted_file(path, executable=False):
    p = Path(path)
    if not p.is_absolute():
        raise ValueError('Configured paths must be absolute: ' + str(p))
    resolved = p.resolve(strict=True)
    for item in [resolved, *resolved.parents]:
        info = item.stat()
        if info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError('Path must be root-owned and not group/world writable: ' + str(item))
    if not resolved.is_file():
        raise ValueError('Expected regular file: ' + str(p))
    if executable and not os.access(resolved, os.X_OK):
        raise ValueError('Configured program is not executable: ' + str(p))
    return str(resolved)


def validate_argv(argv):
    if not isinstance(argv, list) or not 1 <= len(argv) <= 64:
        raise ValueError('Configured argv must be a nonempty list with at most 64 arguments')
    if not all(isinstance(x, str) and len(x) <= 4096 and '\x00' not in x and '\n' not in x for x in argv):
        raise ValueError('Invalid configured argv')
    argv = list(argv)
    program = trusted_file(argv[0], executable=True)
    argv[0] = program
    # Shell/python interpreter command flags would hide which script is being run.
    if Path(program).name in ('bash', 'sh', 'dash', 'python3', 'python3.10', 'python3.11', 'python3.12', 'python3.13', 'python3.14'):
        if len(argv) < 2 or not argv[1].startswith('/'):
            raise ValueError('Interpreter argv must name an absolute trusted script as argument 1')
        argv[1] = trusted_file(argv[1])
    return argv


def trusted_runtime_path(value):
    p = Path(value)
    for item in [p, *p.parents]:
        if item.is_symlink():
            raise ValueError('Runtime paths must not contain symlinks: ' + str(item))
        if item.exists():
            info = item.stat()
            if info.st_uid != 0 or info.st_mode & 0o022:
                raise ValueError('Runtime path must be root-owned and not group/world writable: ' + str(item))


def load_config(path=CONFIG):
    canonical = trusted_file(path)
    with open(canonical, encoding='utf-8') as stream:
        cfg = json.load(stream)
    if cfg.get('role') not in ('source', 'destination'):
        raise ValueError('Host config role must be source or destination')
    if not re.fullmatch(r'/dev/nvme[0-9]+', cfg.get('controller', '')):
        raise ValueError('controller must be /dev/nvmeN')
    if isinstance(cfg.get('cntlid'), bool) or not isinstance(cfg.get('cntlid'), int) or not 0 <= cfg['cntlid'] <= 65535:
        raise ValueError('cntlid must be an integer in 0..65535')
    for name in ('qmp_socket', 'pidfile', 'launch_log'):
        p = Path(cfg[name])
        if not p.is_absolute() or '..' in p.parts:
            raise ValueError(name + ' must be an absolute path without ..')
        trusted_runtime_path(p)
    cfg['qemu_executable'] = trusted_file(cfg['qemu_executable'], executable=True)
    cfg['launch_argv'] = validate_argv(cfg['launch_argv'])
    if cfg['role'] == 'source':
        cfg['migration_argv'] = validate_argv(cfg['migration_argv'])
        trusted_file('/usr/bin/timeout', executable=True)
    for name, value in cfg.get('environment', {}).items():
        if not re.fullmatch(r'[A-Z][A-Z0-9_]*', name) or not isinstance(value, str) or '\x00' in value:
            raise ValueError('Invalid configured environment')
        if name in ('LD_PRELOAD', 'LD_LIBRARY_PATH', 'PYTHONPATH', 'PYTHONHOME', 'BASH_ENV', 'ENV', 'PATH'):
            raise ValueError('Loader/interpreter environment override is not allowed: ' + name)
    timeout = cfg.get('launch_timeout', 90)
    if isinstance(timeout, bool) or not isinstance(timeout, int) or not 1 <= timeout <= 120:
        raise ValueError('launch_timeout must be 1..120 seconds')
    migration_timeout = cfg.get('migration_timeout', 1700)
    if isinstance(migration_timeout, bool) or not isinstance(migration_timeout, int) or not 5 <= migration_timeout <= 7200:
        raise ValueError('migration_timeout must be 5..7200 seconds')
    return cfg


def qmp_status(cfg, expected_pid):
    """Check actual QMP peer credentials, handshake, then query-status."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(2)
    stream = None
    try:
        sock.connect(cfg['qmp_socket'])
        peer_pid, _, _ = struct.unpack('3i', sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        if peer_pid != expected_pid:
            raise ValueError('QMP peer PID does not match the configured QEMU pidfile')
        stream = sock.makefile('rwb', buffering=0)
        deadline = time.monotonic() + 4

        def receive(identifier=None):
            while time.monotonic() < deadline:
                raw = stream.readline(65537)
                if not raw or len(raw) > 65536:
                    raise ValueError('Missing or oversized QMP response')
                response = json.loads(raw)
                if identifier is None and 'QMP' in response:
                    return response
                if response.get('id') == identifier:
                    if 'error' in response:
                        raise ValueError('QMP error: ' + str(response['error']))
                    return response['return']
            raise TimeoutError('QMP response deadline exceeded')

        receive()
        for ident, command in ((1, 'qmp_capabilities'), (2, 'query-status')):
            stream.write((json.dumps({'execute': command, 'id': ident}) + '\n').encode())
            result = receive(ident)
        return result['status']
    finally:
        if stream is not None:
            stream.close()
        sock.close()


def inspect_vm(cfg):
    p = Path(cfg['pidfile'])
    if not p.exists():
        return None
    raw = p.read_text().strip()
    if not re.fullmatch(r'[0-9]{1,10}', raw) or int(raw) < 2:
        raise ValueError('Invalid QEMU pidfile; inspect it manually before retrying')
    pid = int(raw)
    proc = Path('/proc') / str(pid)
    if not proc.exists():
        raise ValueError('Stale QEMU pidfile; remove it only after checking the previous VM has exited')
    actual = os.readlink(proc / 'exe')
    if actual != cfg['qemu_executable']:
        raise ValueError('Pidfile belongs to a different executable; refusing to reuse or signal it')
    status = qmp_status(cfg, pid)
    return {'pid': pid, 'qmp_status': status}


def preflight(cfg):
    checks = []

    def check(name, ok, detail):
        checks.append({'name': name, 'ok': bool(ok), 'detail': detail})

    check('root', os.geteuid() == 0, 'Privileged host bridge requires root')
    check('architecture', os.uname().machine == 'x86_64', os.uname().machine)
    check('BTF', Path('/sys/kernel/btf/vmlinux').is_file(), '/sys/kernel/btf/vmlinux')
    for key, executable in (('daemon', True), ('bpf', False)):
        try:
            trusted_file(cfg[key], executable)
            check(key, True, cfg[key])
        except (OSError, ValueError, KeyError) as exc:
            check(key, False, str(exc))
    check('controller', Path(cfg['controller']).is_char_device(), cfg['controller'])
    tracefs = next((p for p in (Path('/sys/kernel/tracing'), Path('/sys/kernel/debug/tracing')) if (p / 'events').is_dir()), None)
    for event in ('raw_syscalls/sys_enter', 'raw_syscalls/sys_exit', 'nvme/nvme_complete_rq'):
        check('tracepoint:' + event, tracefs and (tracefs / 'events' / event).is_dir(), 'Required for command ownership and completion tracking')
    symbols = set()
    try:
        with open('/proc/kallsyms') as stream:
            for line in stream:
                parts = line.split()
                if len(parts) >= 3:
                    symbols.add(parts[2])
    except OSError:
        pass
    check('nvme_init_request', 'nvme_init_request' in symbols, 'Kernel must expose the supported probe target')
    vm, error = None, None
    try:
        vm = inspect_vm(cfg)
    except (OSError, ValueError, TimeoutError) as exc:
        error = str(exc)
    result = {'ok': all(c['ok'] for c in checks), 'role': cfg['role'], 'controller': cfg['controller'], 'cntlid': cfg['cntlid'], 'checks': checks, 'ready': False}
    if vm:
        result.update(vm)
        result['ready'] = vm['qmp_status'] == ('running' if cfg['role'] == 'source' else 'inmigrate')
    if error:
        result['vm_error'] = error
    return result


def prepare(cfg):
    facts = preflight(cfg)
    if not facts['ok']:
        raise ValueError('Host preflight failed: ' + '; '.join(c['name'] + ': ' + c['detail'] for c in facts['checks'] if not c['ok']))
    vm = inspect_vm(cfg)
    launched = False
    launcher = None
    if vm is None:
        for value in (cfg['pidfile'], cfg['qmp_socket'], cfg['launch_log']):
            Path(value).parent.mkdir(mode=0o750, parents=True, exist_ok=True)
        # An existing orphaned socket can indicate a running untracked VM.
        if Path(cfg['qmp_socket']).exists():
            raise ValueError('QMP socket exists without a valid pidfile; inspect the VM manually')
        env = {'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8'}
        env.update(cfg.get('environment', {}))
        with open(cfg['launch_log'], 'ab', buffering=0) as log:
            launcher = subprocess.Popen(cfg['launch_argv'], stdin=subprocess.DEVNULL, stdout=log, stderr=log, env=env, start_new_session=True)
        launched = True
    deadline = time.monotonic() + cfg.get('launch_timeout', 90)
    expected = 'running' if cfg['role'] == 'source' else 'inmigrate'
    last = 'pidfile has not appeared'
    while time.monotonic() < deadline:
        try:
            vm = inspect_vm(cfg)
            if vm:
                last = 'QMP reports ' + vm['qmp_status']
                if vm['qmp_status'] == expected:
                    return dict(ok=True, role=cfg['role'], controller=cfg['controller'], cntlid=cfg['cntlid'], launched=launched, **vm)
        except (OSError, ValueError, TimeoutError) as exc:
            last = str(exc)
        if launcher is not None and launcher.poll() not in (None, 0):
            raise ValueError('VM launcher failed with rc=' + str(launcher.returncode) + '; inspect ' + cfg['launch_log'])
        time.sleep(.2)
    raise TimeoutError('VM not ready (' + last + '); expected ' + expected + '. Inspect ' + cfg['launch_log'] + '. No VM was killed.')


def migrate(cfg, request, lock_fd=None):
    if cfg['role'] != 'source':
        raise ValueError('Migration must be started on the source host')
    address = ipaddress.ip_address(request['destination_ip'])
    if address.version != 4 or address.is_unspecified or address.is_multicast:
        raise ValueError('The current migration script requires a unicast IPv4 destination address')
    vm = inspect_vm(cfg)
    if not vm or vm['qmp_status'] != 'running':
        raise ValueError('Source VM must be running before migration is started')
    if 'expected_pid' in request:
        expected = request['expected_pid']
        if isinstance(expected, bool) or not isinstance(expected, int) or expected != vm['pid']:
            raise ValueError('Source QEMU PID changed since preparation; prepare and arm again')
    env = {'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8'}
    env.update(cfg.get('environment', {}))
    # v3 reads environment variables directly; it does not source UVP_CONFIG.
    env['SOURCE_QMP'] = cfg['qmp_socket']
    argv = ['/usr/bin/timeout', '--signal=TERM', '--kill-after=5s', str(cfg.get('migration_timeout', 1700)) + 's']
    argv += validate_argv(cfg['migration_argv']) + [str(address)]
    print('UVP migration: source PID=' + str(vm['pid']) + ' destination=' + str(address), flush=True)
    # Separate process group contains the migration script and its helpers only;
    # prepared QEMU processes are never included. timeout supplies an independent
    # remote lifetime bound even if this SSH bridge is killed unexpectedly.
    proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, env=env, start_new_session=True,
                            pass_fds=(() if lock_fd is None else (lock_fd,)))
    interrupted = []

    def stop(signum, _frame):
        interrupted.append(signum)
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass

    previous = {sig: signal.signal(sig, stop) for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)}
    try:
        while True:
            try:
                return proc.wait(timeout=1 if not interrupted else 6)
            except subprocess.TimeoutExpired:
                if interrupted:
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    proc.wait()
                    return 128 + interrupted[0]
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('verb', choices=('preflight', 'prepare', 'migrate'))
    args = parser.parse_args()
    try:
        if os.geteuid() != 0:
            raise ValueError('Run the host bridge as root on a trusted lab machine')
        raw = sys.stdin.buffer.read(16385)
        if len(raw) > 16384:
            raise ValueError('Request exceeds 16 KiB')
        request = json.loads(raw or b'{}')
        if not isinstance(request, dict):
            raise ValueError('Expected JSON object')
        cfg = load_config()
        if request.get('role', cfg['role']) != cfg['role']:
            raise ValueError('Requested role does not match this host config')
        if args.verb == 'preflight':
            result = preflight(cfg)
            print(json.dumps(result), flush=True)
            return 0 if result['ok'] else 1
        lockdir = Path('/run/uvp')
        lockdir.mkdir(mode=0o700, exist_ok=True)
        with open(lockdir / 'host-bridge.lock', 'w') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError('Another host prepare/migrate operation is already running') from None
            if args.verb == 'prepare':
                print(json.dumps(prepare(cfg)), flush=True)
                return 0
            return migrate(cfg, request, lock.fileno())
    except (OSError, ValueError, KeyError, TimeoutError) as exc:
        print(json.dumps({'ok': False, 'error': str(exc)}), flush=True)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
