# SPDX-License-Identifier: GPL-2.0-only
import os
import re
import signal
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
BIN=ROOT/'build/uvp-daemon-selftest'

class DaemonTest(unittest.TestCase):
    def start(self,*extra,action=('/bin/true',),hold=10):
        p=subprocess.Popen([str(BIN),'--selftest','--case','1','--control-stdin','--hold-timeout',str(hold),
                            '--action-timeout','5',*extra,'--',*action],stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT,text=True,bufsize=1)
        self.p=p;self.lines=[]
        def reader():
            for line in p.stdout:self.lines.append(line.rstrip())
        self.reader=threading.Thread(target=reader,daemon=True);self.reader.start()
        self.wait_for('HOLD_READY')
        return p
    def wait_for(self,prefix,timeout=8):
        until=time.monotonic()+timeout
        while time.monotonic()<until:
            for line in self.lines:
                if line.startswith(prefix):return line
            time.sleep(.01)
        self.fail('Missing '+prefix+': '+repr(self.lines))
    def send(self,text):self.p.stdin.write(text+'\n');self.p.stdin.flush()
    def finish(self):
        rc=self.p.wait(10);self.reader.join(2);return rc
    def tearDown(self):
        if not hasattr(self,'p'):return
        if self.p.poll() is None:
            self.p.terminate();self.p.wait(10)
        for pipe in (self.p.stdin,self.p.stdout):
            if pipe and not pipe.closed:pipe.close()
    def test_hold_does_not_execute_guest_until_resume(self):
        with tempfile.TemporaryDirectory() as d:
            f=Path(d)/'guest'
            self.start(action=('/usr/bin/touch',str(f)))
            self.assertFalse(f.exists())
            self.send('resume');self.assertEqual(self.finish(),0)
            self.assertTrue(f.exists())
            self.assertLess(next(i for i,l in enumerate(self.lines) if l.startswith('SIGCONT pid=')),
                            next(i for i,l in enumerate(self.lines) if l.startswith('ACTION_EXEC:')))
    def test_host_action_then_resume(self):
        with tempfile.TemporaryDirectory() as d:
            f=Path(d)/'host'
            self.start('--host-action-program','/usr/bin/touch','--host-action-arg',str(f))
            self.send('action');self.wait_for('HOST_ACTION_DONE')
            self.assertTrue(f.exists());self.assertIsNone(self.p.poll())
            self.assertFalse(any(l.startswith('SIGCONT pid=') for l in self.lines))
            self.send('action');self.wait_for('CONTROL_REJECTED')
            self.send('resume');self.assertEqual(self.finish(),0)
    def test_host_failure_releases_and_fails(self):
        self.start('--host-action-program','/bin/false')
        self.send('action');self.assertNotEqual(self.finish(),0)
        self.assertTrue(any(l.startswith('CLEANUP: SIGCONT') for l in self.lines))
        self.assertFalse(any(l.startswith('ACTION_ACKNOWLEDGED') for l in self.lines))
    def test_eof_releases(self):
        self.start();self.p.stdin.close();self.assertNotEqual(self.finish(),0)
        self.assertTrue(any(l.startswith('CLEANUP: SIGCONT') for l in self.lines))
    def test_cancel_during_host_action(self):
        self.start('--host-action-program','/bin/sleep','--host-action-arg','30')
        self.send('action');self.wait_for('HOST_ACTION_STARTED');self.send('cancel')
        self.assertNotEqual(self.finish(),0)
    def test_hold_deadline(self):
        self.start(hold=1);self.assertNotEqual(self.finish(),0)
        self.assertTrue(any('hold deadline' in l for l in self.lines))
    def test_parent_kill_watchdog_releases_target(self):
        self.start();line=self.wait_for('READY ');pid=int(re.search(r'pid=(\d+)',line)[1])
        self.assertIn('T',Path(f'/proc/{pid}/status').read_text().split('State:')[1].splitlines()[0])
        self.p.kill();self.p.wait(3)
        try:
            self.wait_for('WATCHDOG:',timeout=7)
            until=time.monotonic()+3
            while time.monotonic()<until:
                status=Path(f'/proc/{pid}/status').read_text()
                if '\nState:\tT' not in status:break
                time.sleep(.02)
            self.assertNotIn('\nState:\tT',status)
        finally:
            try:os.kill(pid,signal.SIGKILL)
            except ProcessLookupError:pass
    def test_test_only_build_refuses_real_target(self):
        r=subprocess.run([str(BIN),'--pid',str(os.getpid()),'--case','1','--controller','/dev/nvme0','--cntlid','1','--','/bin/true'],capture_output=True,text=True)
        self.assertEqual(r.returncode,2);self.assertIn('test-only binary',r.stderr)
