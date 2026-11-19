# SPDX-License-Identifier: GPL-2.0-only
# Author: Kundan Kumar <kundan.kumar@samsung.com>
"""End-to-end coordinator tests; simulation never executes device commands."""
import copy
import json
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch

from uvp_server.server import create_server

ROOT = Path(__file__).resolve().parent.parent


class OrchestrationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.config = json.loads((ROOT / 'config/demo.json').read_text())
        # The harmless profile is kept local to this fixture even if demo
        # examples change their human-facing labels or enabled profiles.
        self.config.setdefault('actions', {})['source-test'] = {
            'label': 'Test action', 'kind': 'host', 'host': 'source',
            'enabled': True, 'argv': ['/bin/true'],
        }
        self.server = create_server(self.config, self.tmp.name, 'test-token',
                                    port=0, demo=True)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_address[1]}'

    def tearDown(self):
        self.server.shutdown()
        self.server.controller.close()
        self.server.server_close()
        self.thread.join(2)
        self.tmp.cleanup()

    def request(self, path, body=None):
        headers = {'Authorization': 'Bearer test-token', 'Content-Type': 'application/json'}
        req = urllib.request.Request(self.url + path, headers=headers,
                                     data=None if body is None else json.dumps(body).encode())
        try:
            with urllib.request.urlopen(req, timeout=4) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as exc:
            return exc.code, json.load(exc)

    def wait_for(self, predicate, description='expected state', timeout=6):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            code, state = self.request('/api/state')
            self.assertEqual(code, 200)
            if predicate(state):
                return state
            time.sleep(.025)
        self.fail(f'Did not reach {description}: {state!r}')

    def arm(self, **updates):
        request = {'case': 1, 'pid': 12345, 'controller': '/dev/nvme0',
                   'cntlid': 1, 'hold_seconds': 10, 'checkpoint_seconds': 20}
        request.update(updates)
        return self.request('/api/runs', request)

    def start(self):
        self.wait_for(lambda s: s['run'] and s['run']['status'] == 'ARMED', 'ARMED')
        code, body = self.request('/api/jobs', {'job': 'migrate'})
        self.assertEqual(code, 202, body)

    @staticmethod
    def hosts():
        return {
            'source': {'address': '192.0.2.10', 'user': 'uvp', 'ssh_port': 22,
                       'pid': 12345, 'controller': '/dev/nvme0', 'cntlid': 1},
            'destination': {'address': '192.0.2.11', 'user': 'uvp', 'ssh_port': 22,
                            'pid': 12346, 'controller': '/dev/nvme0', 'cntlid': 2},
        }

    def test_automatic_action_runs_once_then_resumes_without_browser_control(self):
        code, run = self.arm(host_action='source-test', automatic=True, auto_resume=True)
        self.assertEqual(code, 201, run)
        self.start()
        state = self.wait_for(lambda s: s['run']['status'] == 'DONE', 'automatic DONE')
        self.assertEqual(state['run']['host_action_status'], 'DONE')
        messages = [e['message'] for e in state['events'] if e['kind'] == 'daemon']
        self.assertEqual(messages.count('HOST_ACTION_STARTED'), 1)
        self.assertEqual(messages.count('HOST_ACTION_DONE'), 1)
        self.assertEqual(sum(m.startswith('SIGCONT pid=') for m in messages), 1)
        self.assertNotEqual(state['run']['migration_result'], 'PASS')
        self.assertEqual(self.request('/api/runs/' + run['id'] + '/action', {})[0], 409)
        code, exported = self.request('/api/runs/' + run['id'] + '/export')
        self.assertEqual(code, 200)
        self.assertTrue(exported['run']['automatic'])

    def test_automatic_action_can_leave_checkpoint_for_manual_resume(self):
        code, run = self.arm(host_action='source-test', automatic=True, auto_resume=False)
        self.assertEqual(code, 201, run)
        self.start()
        state = self.wait_for(lambda s: s['run']['status'] == 'PAUSED' and
                             s['run']['host_action_status'] == 'DONE', 'held completed action')
        self.assertFalse(any(e['message'].startswith('SIGCONT pid=') for e in state['events']))
        self.assertEqual(self.request('/api/runs/' + run['id'] + '/action', {})[0], 409)
        self.assertEqual(self.request('/api/runs/' + run['id'] + '/resume', {})[0], 200)
        self.wait_for(lambda s: s['run']['status'] == 'DONE', 'manual release DONE')

    def test_automatic_no_action_still_releases_checkpoint(self):
        code, run = self.arm(automatic=True, auto_resume=True)
        self.assertEqual(code, 201, run)
        self.start()
        state = self.wait_for(lambda s: s['run']['status'] == 'DONE')
        self.assertEqual(state['run']['host_action_status'], 'NONE')

    def test_generic_command_requires_valid_numeric_selectors_and_queue(self):
        good = {'opcode': '0x06', 'queue': 'admin', 'nsid': 0, 'nsid_mask': 0,
                'cdw10': 1, 'cdw10_mask': '0xff', 'cdw11': 0, 'cdw11_mask': 0}
        invalid = [dict(good, opcode=256), dict(good, opcode=True),
                   dict(good, opcode='6;id'), dict(good, queue='shell'),
                   dict(good, nsid_mask=-1), dict(good, cdw10=2**32),
                   dict(good, cdw11_mask='$(id)')]
        for selectors in invalid:
            with self.subTest(selectors=selectors):
                self.assertEqual(self.arm(case=5, target_host='source', selectors=selectors)[0], 400)
        self.assertEqual(self.arm(case=5, target_host='elsewhere', selectors=good)[0], 400)
        code, run = self.arm(case=5, target_host='source', selectors=good)
        self.assertEqual(code, 201, run)
        self.wait_for(lambda s: s['run']['status'] == 'ARMED')
        self.assertEqual(run['case'], 5)
        self.assertEqual(run['host'], 'source')
        self.request('/api/runs/' + run['id'] + '/cancel', {})
        self.wait_for(lambda s: s['run']['status'] == 'CANCELLED')

    def test_host_configuration_rejects_shell_text_and_is_atomic(self):
        original = copy.deepcopy(self.server.controller.config['hosts'])
        for field, value in [('address', '192.0.2.10;id'), ('address', '-oProxyCommand=id'),
                             ('user', 'uvp$(id)'), ('ssh_port', 0),
                             ('controller', '/dev/nvme0;id')]:
            payload = self.hosts()
            payload['destination'][field] = value
            with self.subTest(field=field, value=value):
                code, body = self.request('/api/hosts', payload)
                self.assertEqual(code, 400, body)
                self.assertEqual(self.server.controller.config['hosts'], original)

    def test_host_update_rejected_while_hook_is_armed(self):
        code, run = self.arm()
        self.assertEqual(code, 201, run)
        self.wait_for(lambda s: s['run']['status'] == 'ARMED')
        self.assertEqual(self.request('/api/hosts', self.hosts())[0], 409)
        self.assertEqual(self.request('/api/prepare', {})[0], 409)
        self.request('/api/runs/' + run['id'] + '/cancel', {})
        self.wait_for(lambda s: s['run']['status'] == 'CANCELLED')

    def test_start_migration_before_hooks_are_ready_is_rejected(self):
        self.assertEqual(self.request('/api/jobs', {'job': 'migrate'})[0], 409)
        code, run = self.arm()
        self.assertEqual(code, 201, run)
        self.start()
        self.wait_for(lambda s: s['run']['status'] == 'PAUSED')
        self.assertEqual(self.request('/api/jobs', {'job': 'migrate'})[0], 409)
        self.request('/api/runs/' + run['id'] + '/cancel', {})
        self.wait_for(lambda s: s['run']['status'] == 'CANCELLED')

    def test_prepare_waits_for_destination_before_source_and_records_pids(self):
        calls = []

        def bridge(side, verb, payload=None):
            calls.append((side, verb))
            host = self.server.controller.config['hosts'][side]
            return {'ok': True, 'role': side, 'pid': 20001 if side == 'source' else 20002,
                    'controller': host['controller'], 'cntlid': host['cntlid'],
                    'qmp_status': 'running' if side == 'source' else 'inmigrate'}

        with patch.object(self.server.controller, '_bridge', side_effect=bridge):
            code, body = self.request('/api/prepare', {})
            self.assertEqual(code, 202, body)
            self.wait_for(lambda s: s.get('setup', {}).get('status') == 'READY', 'both hosts READY')
        self.assertEqual(calls, [('destination', 'prepare'), ('source', 'prepare')])
        _, config = self.request('/api/config')
        self.assertEqual(config['hosts']['source']['pid'], 20001)
        self.assertEqual(config['hosts']['destination']['pid'], 20002)

    def test_failed_destination_prepare_does_not_launch_source(self):
        calls = []

        def bridge(side, verb, payload=None):
            calls.append((side, verb))
            raise RuntimeError('Destination QMP not ready')

        with patch.object(self.server.controller, '_bridge', side_effect=bridge):
            code, body = self.request('/api/prepare', {})
            self.assertEqual(code, 202, body)
            state = self.wait_for(lambda s: s.get('setup', {}).get('status') == 'FAILED',
                                  'failed preparation')
        self.assertEqual(calls, [('destination', 'prepare')])
        self.assertIn('Destination QMP not ready', state['setup']['detail'])
        self.assertEqual(self.request('/api/jobs', {'job': 'migrate'})[0], 409)

    def test_prepare_rejects_device_drift_before_launching_source(self):
        with patch.object(self.server.controller, '_bridge', return_value={
                'ok': True, 'role': 'destination', 'pid': 20002,
                'controller': '/dev/nvme999', 'cntlid': 2,
                'qmp_status': 'inmigrate'}) as bridge:
            self.assertEqual(self.request('/api/prepare', {})[0], 202)
            state = self.wait_for(lambda s: s.get('setup', {}).get('status') == 'FAILED')
        self.assertEqual(bridge.call_count, 1)
        self.assertIn('device settings differ', state['setup']['detail'])

    def test_inflight_prepare_blocks_host_changes_and_arming(self):
        entered, release = threading.Event(), threading.Event()

        def bridge(side, verb, payload=None):
            entered.set()
            if not release.wait(3):
                raise TimeoutError('Test did not release bridge')
            host = self.server.controller.config['hosts'][side]
            return {'ok': True, 'role': side, 'pid': 20001 if side == 'source' else 20002,
                    'controller': host['controller'], 'cntlid': host['cntlid'],
                    'qmp_status': 'running' if side == 'source' else 'inmigrate'}

        with patch.object(self.server.controller, '_bridge', side_effect=bridge):
            self.assertEqual(self.request('/api/prepare', {})[0], 202)
            self.assertTrue(entered.wait(2))
            try:
                self.assertEqual(self.arm()[0], 409)
                self.assertEqual(self.request('/api/hosts', self.hosts())[0], 409)
                self.assertEqual(self.request('/api/preflight', {})[0], 409)
            finally:
                release.set()
            self.wait_for(lambda s: s.get('setup', {}).get('status') == 'READY')

    def test_migration_case_cannot_override_verified_prepared_pid(self):
        controller = self.server.controller
        with controller.lock:
            controller.config['require_prepare'] = True
            controller.setup = {'status': 'READY', 'detail': 'Test hosts verified', 'hosts': {}}
            controller.config['hosts']['source']['pid'] = 12345
            controller.config['hosts']['destination']['pid'] = 23456
        for case in (1, 2, 3, 4):
            with self.subTest(case=case):
                code, body = self.arm(case=case, pid=54321)
                self.assertEqual(code, 409, body)
        # A generic synchronous command may intentionally target an external
        # issuer; that explicit selection remains supported.
        code, run = self.arm(case=5, pid=54321, target_host='source',
                             selectors={'opcode': 6, 'queue': 'admin'})
        self.assertEqual(code, 201, run)
        self.wait_for(lambda s: s['run']['status'] == 'ARMED')
        self.request('/api/runs/' + run['id'] + '/cancel', {})
        self.wait_for(lambda s: s['run']['status'] == 'CANCELLED')

    def test_destructive_action_requires_exact_configured_target_ack(self):
        self.server.controller.config['actions']['source-delete-test'] = {
            'label': 'Delete test namespace', 'kind': 'host', 'host': 'source',
            'enabled': True, 'argv': ['/bin/true'], 'destructive': True,
            'controller': '/dev/nvme7', 'nsid': 3,
            'confirmation': '/dev/nvme7:3',
        }
        for ack in (None, '', '/dev/nvme0:3', '/dev/nvme7:4'):
            with self.subTest(ack=ack):
                code, body = self.arm(host_action='source-delete-test', destructive_ack=ack)
                self.assertEqual(code, 400, body)
        code, run = self.arm(host_action='source-delete-test', destructive_ack='/dev/nvme7:3')
        self.assertEqual(code, 201, run)
        self.wait_for(lambda s: s['run']['status'] == 'ARMED')
        self.request('/api/runs/' + run['id'] + '/cancel', {})
        self.wait_for(lambda s: s['run']['status'] == 'CANCELLED')


if __name__ == '__main__':
    unittest.main()
