# SPDX-License-Identifier: GPL-2.0-only
# Author: Kundan Kumar <kundan.kumar@samsung.com>
"""Loopback-only lab controller. Use an SSH tunnel for remote access."""
import argparse
import hmac
import json
import os
import re
import secrets
import signal
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
from .core import Controller, RequestError, ROOT

class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

class Handler(BaseHTTPRequestHandler):
    server_version = 'UVP/1.0'
    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, fmt, *args):
        pass  # tokens and query strings never go into request logs

    def reply(self, code, body, content_type='application/json'):
        if isinstance(body,(dict,list)):
            body=json.dumps(body).encode()
        if isinstance(body,str): body=body.encode()
        self.send_response(code)
        self.send_header('Content-Type',content_type)
        self.send_header('Content-Length',str(len(body)))
        self.send_header('Cache-Control','no-store')
        self.send_header('X-Content-Type-Options','nosniff')
        self.send_header('Referrer-Policy','no-referrer')
        self.send_header('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
        self.end_headers()
        self.wfile.write(body)

    def allowed(self, auth=True):
        host=self.headers.get('Host','')
        if host not in self.server.allowed_hosts:
            raise RequestError('Unexpected Host header',403)
        origin=self.headers.get('Origin')
        if origin and origin not in ('http://'+host,'https://'+host):
            raise RequestError('Cross-origin request refused',403)
        if self.headers.get('Sec-Fetch-Site')=='cross-site':
            raise RequestError('Cross-site request refused',403)
        token=self.headers.get('Authorization','').removeprefix('Bearer ')
        if auth and not hmac.compare_digest(token,self.server.token):
            raise RequestError('Enter the access token printed by the server',401)

    def do_GET(self):
        try:
            path=urlsplit(self.path).path
            self.allowed(auth=path.startswith('/api/') and path!='/api/info')
            if path=='/api/info':
                return self.reply(200,{'mode':'demo' if self.server.controller.demo else 'hardware'})
            if path=='/api/config': return self.reply(200,self.server.controller.public_config())
            if path=='/api/state': return self.reply(200,self.server.controller.snapshot())
            m=re.fullmatch(r'/api/runs/([a-f0-9]{12})/export',path)
            if m: return self.reply(200,self.server.controller.export(m[1]))
            routes={'/':('index.html','text/html; charset=utf-8'),'/app.js':('app.js','text/javascript; charset=utf-8'),'/style.css':('style.css','text/css; charset=utf-8')}
            if path not in routes: raise RequestError('Not found',404)
            file,typ=routes[path]
            return self.reply(200,(ROOT/'web'/file).read_bytes(),typ)
        except RequestError as e: self.reply(e.status,{'error':str(e)})
        except (BrokenPipeError,ConnectionResetError): pass

    def do_POST(self):
        try:
            self.allowed()
            if self.headers.get('Content-Type','').split(';')[0]!='application/json':
                raise RequestError('Use application/json',415)
            try: size=int(self.headers.get('Content-Length','0'))
            except ValueError: raise RequestError('Invalid content length')
            if not 0<size<=16384: raise RequestError('Request body too large or missing',413)
            try: data=json.loads(self.rfile.read(size))
            except (ValueError,UnicodeError): raise RequestError('Invalid JSON')
            if not isinstance(data,dict): raise RequestError('Expected JSON object')
            path=urlsplit(self.path).path
            c=self.server.controller
            if path=='/api/hosts': return self.reply(200,c.update_hosts(data))
            if path=='/api/prepare': return self.reply(202,c.setup_hosts('prepare'))
            if path=='/api/preflight': return self.reply(202,c.setup_hosts('preflight'))
            if path=='/api/runs': return self.reply(201,c.arm(data))
            m=re.fullmatch(r'/api/runs/([a-f0-9]{12})/(resume|action|cancel)',path)
            if m: return self.reply(200,c.control(m[1],m[2]))
            if path=='/api/jobs': return self.reply(202,c.launch_job(data.get('job')))
            raise RequestError('Not found',404)
        except RequestError as e: self.reply(e.status,{'error':str(e)})
        except (BrokenPipeError,ConnectionResetError): pass
        except Exception as e:
            self.server.controller.event('error','HTTP operation failed: '+str(e))
            self.reply(500,{'error':'Operation failed; inspect event log'})


def create_server(config, data_dir, token, port=8000, demo=False, allowed_host=None):
    s=Server(('127.0.0.1',port),Handler)
    s.controller=Controller(config,data_dir,demo)
    s.token=token
    actual=s.server_address[1]
    s.allowed_hosts={f'127.0.0.1:{actual}',f'localhost:{actual}'}
    # Preview host is an explicit demo-only option, never accepted in hardware mode.
    if demo and allowed_host: s.allowed_hosts.add(allowed_host)
    return s


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config',default=str(ROOT/'config'/'demo.json'))
    p.add_argument('--hardware',action='store_true',help='Enable configured real daemon/commands')
    p.add_argument('--port',type=int,default=8000)
    p.add_argument('--host',choices=['127.0.0.1'],default='127.0.0.1',help=argparse.SUPPRESS)
    p.add_argument('--strictPort',action='store_true',help=argparse.SUPPRESS)
    p.add_argument('--data-dir',default=str(ROOT/'var'))
    p.add_argument('--demo-preview-host',help='Explicit Host header for local demo preview proxy')
    a=p.parse_args()
    config=json.loads(Path(a.config).read_text())
    if a.hardware and config.get('demo'):
        p.error('Hardware mode requires a hardware config, not demo.json')
    token=os.environ.get('UVP_TOKEN') or ('uvp-demo' if not a.hardware else secrets.token_urlsafe(32))
    if a.hardware and len(token)<24: p.error('UVP_TOKEN must contain at least 24 characters')
    server=create_server(config,a.data_dir,token,a.port,not a.hardware,a.demo_preview_host)
    print(f'UVP {"HARDWARE" if a.hardware else "DEMO"} http://127.0.0.1:{server.server_address[1]}',flush=True)
    print('Access token: '+token,flush=True)
    def shutdown(sig,frame):
        threading.Thread(target=server.shutdown,daemon=True).start()
    signal.signal(signal.SIGINT,shutdown)
    signal.signal(signal.SIGTERM,shutdown)
    try: server.serve_forever(poll_interval=.2)
    finally:
        server.controller.close()
        server.server_close()

if __name__=='__main__': main()
