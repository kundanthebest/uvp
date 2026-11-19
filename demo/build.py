from pathlib import Path
import json, re
here=Path(__file__).resolve().parent
repo=here.parent
page=(repo/'web/index.html').read_text()
css=(repo/'web/style.css').read_text()
js=(repo/'web/app.js').read_text()
cfg=json.loads((repo/'config/demo.json').read_text())
cfg['mode']='demo'
cfg['require_prepare']=True
cfg['phases']=[dict(id=i+1,name=n,host=h,symbol=s) for i,(n,h,s) in enumerate([
    ('Suspend complete','source','nvmevf_cmd_suspend_device'),('Get controller state complete','source','nvmevf_cmd_get_ctrl_state'),
    ('Set controller state complete','destination','nvmevf_cmd_set_ctrl_state'),('Resume complete','destination','nvmevf_cmd_resume_device'),
    ('Custom NVMe command','Selected host','Synchronous NVMe syscall')])]
cfg={k:cfg[k] for k in ['mode','require_prepare','phases','hosts','jobs','actions']}
for h in cfg['hosts'].values():
    for k in list(h):
        if k not in ['address','user','pid','controller','cntlid','ssh_port','ssh_target']: del h[k]
for j in cfg['jobs'].values():
    for k in list(j):
        if k not in ['label','kind','host','enabled']: del j[k]
page=page.replace('<title>UVP — NVMe fault orchestration</title>','<title>UVP — Offline demo</title><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'; script-src \'unsafe-inline\'; img-src data:; connect-src \'none\'; base-uri \'none\'; form-action \'none\'">')
page=page.replace('<link rel="stylesheet" href="/style.css"><script defer src="/app.js"></script>','<style>'+css+'\n#auth-toggle {display:none}</style>')
page=page.replace('href="/" aria-label="UVP home"','href="#control-panel" aria-label="UVP home"')
page=page.replace('Open this console through an SSH tunnel. Your Linux servers do the work.', 'This demo runs in your browser. Open the full project to connect your Linux servers.')
page=page.replace('DEMO ENVIRONMENT','OFFLINE DEMO').replace('Explore the complete workflow. No devices, processes, or migration jobs are changed.','Use the example IPs, click Prepare hosts, then load the hooks and start a simulated migration. Run history lasts until you close or refresh this tab.').replace('PERSISTENT LOG','THIS TAB')
page=page.replace('Linux execution · Windows browser control','Offline browser simulation')
js=re.sub(r'async function api\(path,body\)\{.*?\}\nasync function action', 'async function api(path,body){return previewRequest(path,body);}\nasync function action',js,count=1,flags=re.S)
js=re.sub(r"try\{token=sessionStorage.*?catch\(_\)\{\}", "token='uvp-demo';",js,count=1)
js=js.replace("try{sessionStorage.setItem('uvp-token',token);}catch(_){}",'')
js=js.replace("await fetch('/api/info').then(r=>r.json())","await api('/api/info')").replace("connected?'Controller connected'","connected?'Offline simulation ready'")
assert 'fetch(' not in js
page=page.replace('</body>', '<script>\n'+(here/'adapter.js').read_text()+'\nconst previewRequest = createPreview('+json.dumps(cfg).replace('</','<\\/')+');\n'+js+'\n</script>\n</body>')
(here/'uvp-demo.html').write_text(page)
