# SPDX-License-Identifier: GPL-2.0-only
import copy
import json
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from uvp_server.server import create_server
from uvp_server.core import Controller, RequestError, host_command
ROOT=Path(__file__).resolve().parent.parent

class APITest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.config=json.loads((ROOT/'config/demo.json').read_text())
        self.server=create_server(self.config,self.tmp.name,'test-token',port=0,demo=True)
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.url=f'http://127.0.0.1:{self.server.server_address[1]}'
    def tearDown(self):
        self.server.shutdown();self.server.controller.close();self.server.server_close();self.thread.join(2)
        self.tmp.cleanup()
    def req(self,path,body=None,token='test-token',headers=None):
        h={'Authorization':'Bearer '+token,'Content-Type':'application/json'};h.update(headers or {})
        req=urllib.request.Request(self.url+path,data=json.dumps(body).encode() if body is not None else None,headers=h)
        try:
            with urllib.request.urlopen(req,timeout=3) as r:return r.status,json.load(r)
        except urllib.error.HTTPError as e:return e.code,json.load(e)
    def wait(self,status):
        until=time.monotonic()+5
        while time.monotonic()<until:
            _,s=self.req('/api/state')
            if s['run'] and s['run']['status']==status:return s
            time.sleep(.03)
        self.fail('Did not reach '+status+': '+repr(s))
    def arm(self,**extra):
        body={'case':1,'pid':12345,'controller':'/dev/nvme0','cntlid':'0x01','hold_seconds':10};body.update(extra)
        return self.req('/api/runs',body)
    def test_authenticated_complete_cycle_and_export(self):
        code,r=self.arm(host_action='source-custom',guest_action='source-fio');self.assertEqual(code,201)
        self.wait('ARMED');self.assertEqual(self.req('/api/jobs',{'job':'migrate'})[0],202);self.wait('PAUSED')
        self.assertEqual(self.req('/api/runs/'+r['id']+'/action',{})[0],200);self.wait('PAUSED')
        self.assertEqual(self.req('/api/runs/'+r['id']+'/resume',{})[0],200);s=self.wait('DONE')
        self.assertEqual(s['run']['migration_result'],'NOT VERIFIED')
        self.assertEqual(s['run']['guest_action_status'],'ACKNOWLEDGED')
        code,e=self.req('/api/runs/'+r['id']+'/export');self.assertEqual(code,200);self.assertGreater(len(e['events']),5)
    def test_auth_origin_host_and_body_validation(self):
        self.assertEqual(self.req('/api/state',token='bad')[0],401)
        self.assertEqual(self.req('/api/runs',{},headers={'Origin':'https://evil.example'})[0],403)
        self.assertEqual(self.req('/api/state',headers={'Host':'evil.example'})[0],403)
        for change in [{'pid':True},{'pid':'1;touch /tmp/no'},{'cntlid':1.2},{'controller':'/dev/nvme0n1'},{'hold_seconds':99999},{'case':9}]:
            self.assertEqual(self.arm(**change)[0],400)
    def test_invalid_state_stale_id_and_duplicate_arm(self):
        self.assertEqual(self.req('/api/jobs',{'job':'migrate'})[0],409)
        _,r=self.arm();self.wait('ARMED')
        self.assertEqual(self.arm()[0],409)
        self.assertEqual(self.req('/api/runs/'+r['id']+'/resume',{})[0],409)
        self.assertEqual(self.req('/api/runs/000000000000/cancel',{})[0],409)
        self.assertEqual(self.req('/api/runs/'+r['id']+'/cancel',{})[0],200);self.wait('CANCELLED')
    def test_disabled_action_and_wrong_host(self):
        self.server.controller.config['actions']['source-custom']['enabled']=False
        self.assertEqual(self.arm(host_action='source-custom')[0],400)
        self.assertEqual(self.arm(host_action='destination-custom')[0],400)
    def test_cancel_held_run(self):
        _,r=self.arm();self.wait('ARMED');self.req('/api/jobs',{'job':'migrate'});self.wait('PAUSED')
        self.req('/api/runs/'+r['id']+'/cancel',{});s=self.wait('CANCELLED')
        self.assertEqual(s['run']['guest_action_status'],'NONE')
    def test_setup_job_and_no_arbitrary_command_endpoint(self):
        self.assertEqual(self.req('/api/jobs',{'job':'source'})[0],202)
        self.assertEqual(self.req('/api/jobs',{'job':'/bin/sh -c id'})[0],400)
        self.assertEqual(self.req('/api/exec',{'command':'id'})[0],404)
    def test_job_deadline_and_duplicate_migration_guard(self):
        c=self.server.controller
        c.demo=False  # run only this harmless local /bin/sleep job
        c.config['jobs']['sleep']={'label':'bounded test','enabled':True,'kind':'setup','host':'source','argv':['/bin/sleep','5'],'timeout':.1}
        self.assertEqual(self.req('/api/jobs',{'job':'sleep'})[0],202)
        until=time.monotonic()+4
        while time.monotonic()<until and c.snapshot()['job']['status']=='RUNNING':time.sleep(.02)
        self.assertEqual(c.snapshot()['job']['status'],'TIMEOUT')
        c.demo=True
        _,r=self.arm();self.wait('ARMED')
        with c.lock:c.run['migration_started']=True;c.save()
        self.assertEqual(self.req('/api/jobs',{'job':'migrate'})[0],409)
        self.req('/api/runs/'+r['id']+'/cancel',{});self.wait('CANCELLED')

    def test_ssh_argv_quoting(self):
        c=host_command({'transport':'ssh','ssh_target':'uvp@host'},['/bin/echo','x; $(id)',"a'b"])
        self.assertIn('StrictHostKeyChecking=yes',c)
        self.assertEqual(c[-1],"/bin/echo 'x; $(id)' 'a'\"'\"'b'")
        with self.assertRaises(RequestError):host_command({'transport':'ssh','ssh_target':'-evil'},['/bin/true'])
    def test_restart_marks_stale_active_run(self):
        c=self.server.controller
        with c.lock:
            c.run={'id':'abc123abc123','status':'PAUSED'};c.save();c.run=None
        other=Controller(self.config,self.tmp.name,True)
        self.assertEqual(other.snapshot()['history'][0]['status'],'INTERRUPTED');other.db.close()

class NativeAdapterTest(unittest.TestCase):
    """Exercise coordinator -> real C control loop, with BPF deliberately disabled."""
    def test_coordinator_to_c_daemon_and_action_output_isolation(self):
        import sys
        with tempfile.TemporaryDirectory() as d:
            shim=Path(d)/'daemon-shim'
            binary=str(ROOT/'build/uvp-daemon-selftest')
            shim.write_text('#!'+sys.executable+'\nimport os,sys\na=sys.argv[1:]\ni=a.index("--pid");del a[i:i+2]\nos.execv('+repr(binary)+',['+repr(binary)+',"--selftest"]+a)\n')
            shim.chmod(0o755)
            config=json.loads((ROOT/'config/demo.json').read_text())
            config['demo']=False
            for h in config['hosts'].values():h.update(daemon=str(shim),privilege_prefix=[],transport='local')
            config['actions']['source-custom']['argv']=['/bin/echo','HOLD_READY timeout_s=9999']
            c=Controller(config,Path(d)/'data',False)
            def wait(status):
                until=time.monotonic()+5
                while time.monotonic()<until:
                    if c.snapshot()['run']['status']==status:return
                    time.sleep(.02)
                self.fail(str(c.snapshot()))
            try:
                r=c.arm({'case':1,'pid':12345,'host_action':'source-custom','hold_seconds':10})
                wait('PAUSED');deadline=c.snapshot()['run']['hold_deadline']
                c.control(r['id'],'action');wait('PAUSED')
                self.assertEqual(c.snapshot()['run']['hold_deadline'],deadline)
                self.assertTrue(any(e['kind']=='daemon-stderr' and e['message']=='HOLD_READY timeout_s=9999' for e in c.snapshot()['events']))
                c.control(r['id'],'resume');wait('DONE')
                self.assertEqual(c.snapshot()['run']['migration_result'],'NOT VERIFIED')
            finally:c.close()
