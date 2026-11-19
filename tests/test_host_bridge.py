"""Host adapters tested with disposable local processes/sockets, never NVMe hardware."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import struct
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch, Mock

ROOT = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


bridge = module('host-bridge')
action = module('host-action')


class HostBridgeTests(unittest.TestCase):
    def test_qmp_wire_protocol_filters_events_and_matches_ids(self):
        replies = iter([b'{"QMP":{}}\n', b'{"event":"RESUME"}\n', b'{"return":{},"id":1}\n', b'{"return":{"status":"inmigrate"},"id":2}\n'])
        stream = Mock()
        stream.readline.side_effect = lambda size: next(replies)
        sock = Mock()
        sock.getsockopt.return_value = struct.pack('3i', 100, 0, 0)
        sock.makefile.return_value = stream
        with patch.object(bridge.socket, 'socket', return_value=sock):
            self.assertEqual(bridge.qmp_status({'qmp_socket': '/run/qmp'}, 100), 'inmigrate')
        requests = [json.loads(call.args[0]) for call in stream.write.call_args_list]
        self.assertEqual(requests, [{'execute': 'qmp_capabilities', 'id': 1}, {'execute': 'query-status', 'id': 2}])

    def test_qmp_wire_protocol_refuses_wrong_peer_before_commands(self):
        sock = Mock()
        sock.getsockopt.return_value = struct.pack('3i', 101, 0, 0)
        with patch.object(bridge.socket, 'socket', return_value=sock):
            with self.assertRaisesRegex(ValueError, 'peer PID'):
                bridge.qmp_status({'qmp_socket': '/run/qmp'}, 100)
        sock.makefile.assert_not_called()

    def test_qmp_handshake_uses_exact_peer(self):
        with tempfile.TemporaryDirectory() as temp:
            path = str(Path(temp) / 'qmp.sock')
            try:
                listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            except PermissionError:
                self.skipTest('AF_UNIX socket creation is blocked by this execution environment')
            listener.bind(path)
            listener.listen(1)
            observed = []

            def serve():
                conn, _ = listener.accept()
                with conn, conn.makefile('rwb', buffering=0) as stream:
                    stream.write(b'{"QMP":{"version":{}}}\n')
                    for _ in range(2):
                        request = json.loads(stream.readline())
                        observed.append(request['execute'])
                        result = {} if request['execute'] == 'qmp_capabilities' else {'status': 'inmigrate'}
                        # Interleaved async events must not be mistaken for replies.
                        stream.write(b'{"event":"RESUME"}\n')
                        stream.write((json.dumps({'return': result, 'id': request['id']}) + '\n').encode())

            thread = threading.Thread(target=serve)
            thread.start()
            try:
                self.assertEqual(bridge.qmp_status({'qmp_socket': path}, os.getpid()), 'inmigrate')
            finally:
                thread.join(3)
                listener.close()
            self.assertFalse(thread.is_alive())
            self.assertEqual(observed, ['qmp_capabilities', 'query-status'])

    def test_qmp_rejects_wrong_peer_pid(self):
        with tempfile.TemporaryDirectory() as temp:
            path = str(Path(temp) / 'qmp.sock')
            try:
                listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            except PermissionError:
                self.skipTest('AF_UNIX socket creation is blocked by this execution environment')
            listener.bind(path)
            listener.listen(1)
            try:
                with self.assertRaisesRegex(ValueError, 'peer PID'):
                    bridge.qmp_status({'qmp_socket': path}, os.getpid() + 100000)
            finally:
                listener.close()

    def test_pidfile_rejects_different_executable(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'qemu.pid'
            path.write_text(str(os.getpid()))
            with self.assertRaisesRegex(ValueError, 'different executable'):
                bridge.inspect_vm({'pidfile': str(path), 'qemu_executable': '/not/the/current/process'})

    def test_pidfile_identity_then_qmp(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'qemu.pid'
            path.write_text(str(os.getpid()))
            with patch.object(bridge, 'qmp_status', return_value='running') as qmp:
                result = bridge.inspect_vm({'pidfile': str(path), 'qemu_executable': os.readlink('/proc/self/exe')})
                self.assertEqual(result, {'pid': os.getpid(), 'qmp_status': 'running'})
                self.assertEqual(qmp.call_args.args[1], os.getpid())

    def test_argv_uses_canonical_paths(self):
        with patch.object(bridge, 'trusted_file', side_effect=['/usr/bin/bash', '/opt/trusted/launch.sh']):
            self.assertEqual(bridge.validate_argv(['/bin/bash', '/alias/launch.sh']), ['/usr/bin/bash', '/opt/trusted/launch.sh'])

    def test_interpreter_inline_command_refused(self):
        with patch.object(bridge, 'trusted_file', return_value='/usr/bin/bash'):
            with self.assertRaisesRegex(ValueError, 'absolute trusted script'):
                bridge.validate_argv(['/bin/bash', '-c', 'echo hello'])

    def test_migration_rejects_pid_change_before_execution(self):
        with patch.object(bridge, 'inspect_vm', return_value={'pid': 100, 'qmp_status': 'running'}), patch.object(bridge.subprocess, 'Popen') as popen:
            with self.assertRaisesRegex(ValueError, 'PID changed'):
                bridge.migrate({'role': 'source'}, {'destination_ip': '192.0.2.20', 'expected_pid': 101})
            popen.assert_not_called()

    def test_migration_rejects_wrong_runstate(self):
        with patch.object(bridge, 'inspect_vm', return_value={'pid': 100, 'qmp_status': 'paused'}), patch.object(bridge.subprocess, 'Popen') as popen:
            with self.assertRaisesRegex(ValueError, 'must be running'):
                bridge.migrate({'role': 'source'}, {'destination_ip': '192.0.2.20'})
            popen.assert_not_called()

    def test_migration_rejects_non_ipv4_and_shell_text(self):
        for target in ('::1', '192.0.2.1;touch /tmp/x', '0.0.0.0', '224.0.0.1'):
            with self.subTest(target=target), patch.object(bridge.subprocess, 'Popen') as popen:
                with self.assertRaises(ValueError):
                    bridge.migrate({'role': 'source'}, {'destination_ip': target})
                popen.assert_not_called()

    def test_migration_has_independent_timeout_and_correct_target(self):
        cfg = {'role': 'source', 'qmp_socket': '/run/uvp/source.qmp', 'migration_argv': ['/bin/bash', '/opt/migrate.sh'], 'environment': {'HMLM_CTRL': '/dev/nvme0'}, 'migration_timeout': 50}
        proc = Mock()
        proc.wait.return_value = 0
        with patch.object(bridge, 'inspect_vm', return_value={'pid': 100, 'qmp_status': 'running'}), patch.object(bridge, 'validate_argv', side_effect=lambda a: a), patch.object(bridge.subprocess, 'Popen', return_value=proc) as popen:
            self.assertEqual(bridge.migrate(cfg, {'destination_ip': '192.0.2.20', 'expected_pid': 100}, 9), 0)
        args, kwargs = popen.call_args
        self.assertEqual(args[0], ['/usr/bin/timeout', '--signal=TERM', '--kill-after=5s', '50s', '/bin/bash', '/opt/migrate.sh', '192.0.2.20'])
        self.assertTrue(kwargs['start_new_session'])
        self.assertEqual(kwargs['pass_fds'], (9,))
        self.assertEqual(kwargs['env']['SOURCE_QMP'], cfg['qmp_socket'])

    def test_prepare_reuses_only_expected_runstate(self):
        cfg = {'role': 'destination', 'controller': '/dev/nvme0', 'cntlid': 2, 'launch_timeout': 1}
        with patch.object(bridge, 'preflight', return_value={'ok': True}), patch.object(bridge, 'inspect_vm', return_value={'pid': 123, 'qmp_status': 'inmigrate'}), patch.object(bridge.subprocess, 'Popen') as popen:
            result = bridge.prepare(cfg)
            self.assertFalse(result['launched'])
            self.assertEqual(result['pid'], 123)
            popen.assert_not_called()


class HostActionTests(unittest.TestCase):
    def test_namespace_delete_one_explicit_target(self):
        with patch.object(sys, 'argv', ['host-action.py', 'namespace-delete', '/dev/nvme8', '--nsid', '7']), patch.object(action.os, 'geteuid', return_value=0), patch.object(Path, 'is_char_device', return_value=True), patch.object(action.shutil, 'which', return_value='/usr/sbin/nvme'), patch.object(action.subprocess, 'call', return_value=0) as call:
            self.assertEqual(action.main(), 0)
            self.assertEqual(call.call_args.args[0], ['/usr/sbin/nvme', 'delete-ns', '/dev/nvme8', '--namespace-id=7'])

    def test_namespace_delete_never_all_namespaces(self):
        for value in ('0', '-1', '4294967295'):
            with self.subTest(value=value), patch.object(sys, 'argv', ['host-action.py', 'namespace-delete', '/dev/nvme8', '--nsid', value]), patch.object(action.os, 'geteuid', return_value=0), patch.object(Path, 'is_char_device', return_value=True), patch.object(action.shutil, 'which', return_value='/usr/sbin/nvme'), patch.object(action.subprocess, 'call') as call:
                with self.assertRaises(SystemExit):
                    action.main()
                call.assert_not_called()


if __name__ == '__main__':
    unittest.main()
