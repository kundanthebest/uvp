const fs=require('fs'), vm=require('vm'), assert=require('assert/strict');
const html=fs.readFileSync(__dirname+'/uvp-demo.html','utf8');
const chunks=[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];assert.equal(chunks.length,1);
const js=chunks[0][1];new vm.Script(js);assert.ok(!js.includes('fetch('));assert.ok(html.includes("connect-src 'none'"));
const pre=js.slice(0,js.indexOf("const previewRequest ="));
const cfg=JSON.parse(js.match(/const previewRequest = createPreview\((.*?)\);/)[1]);
const ctx={};vm.runInNewContext(pre,ctx);
let time=10000,queue=[];
function later(fn,delay){queue.push({t:time+delay,fn});}
function tick(delay){const end=time+delay;while(true){queue.sort((a,b)=>a.t-b.t);const e=queue[0];if(!e||e.t>end)break;time=e.t;queue.shift();e.fn();}time=end;}
const request=ctx.createPreview(cfg,later,()=>time);
function read(){return request('/api/state');}
function prep(){request('/api/hosts',cfg.hosts);request('/api/prepare',{});tick(900);assert.equal(read().setup.status,'READY');}
function run(extra){prep();const r=request('/api/runs',{case:1,target_host:'source',host_action:'source-nvme-reset',guest_action:'none',pid:12345,automatic:true,auto_resume:true,hold_seconds:10,checkpoint_seconds:300,...extra});tick(1000);assert.equal(read().run.status,'ARMED');request('/api/jobs',{job:'migrate'});return r;}
const first=run({});tick(4500);assert.equal(read().run.status,'DONE');assert.equal(read().run.host_action_status,'DONE');assert.equal(request('/api/runs/'+first.id+'/export').events.filter(e=>e.kind==='action').length,2);
const second=run({automatic:false,auto_resume:false});tick(1300);assert.equal(read().run.status,'PAUSED');request('/api/runs/'+second.id+'/action',{});tick(1400);assert.equal(read().run.status,'PAUSED');request('/api/runs/'+second.id+'/resume',{});tick(1200);assert.equal(read().run.status,'DONE');
const third=run({case:5,selectors:{opcode:6,queue:'admin',nsid:0,nsid_mask:0,cdw10:1,cdw10_mask:255,cdw11:0,cdw11_mask:0},automatic:false});tick(1300);request('/api/runs/'+third.id+'/cancel',{});tick(15000);assert.equal(read().run.status,'CANCELLED');
prep();assert.throws(()=>request('/api/runs',{case:1,pid:12345,hold_seconds:10,checkpoint_seconds:300,host_action:'source-delete-ns'}),/namespace/);
console.log('PASS single-file JavaScript syntax, offline transport, automatic action/release, manual action/release, custom command, cancellation, destructive-target acknowledgement, export');
