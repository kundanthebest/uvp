// Offline controller. All state and events live in the current browser tab.
function createPreview(config, timer = setTimeout, now = Date.now) {
  const runs = [];
  const events = [];
  let current = null;
  let job = null;
  let setup = {status: 'IDLE', detail: 'Use the example IPs and click Prepare hosts.'};
  const clone = value => JSON.parse(JSON.stringify(value));
  function log(kind, message, run = null) {
    events.push({seq: events.length + 1, time: now() / 1000, kind, message, run_id: run?.id || null});
  }
  function check(condition, message) {
    if (!condition) throw Error(message);
  }
  function active(run) {
    return run && !['DONE','CANCELLED','FAILED'].includes(run.status);
  }
  function after(run, delay, expected, fn) {
    timer(() => { if (run === current && run.status === expected) fn(); }, delay);
  }
  function finishJob(run) {
    if (!run.migration_started || run.migration_script_status !== 'RUNNING') return;
    run.migration_script_status = 'SIMULATED';
    job.status = 'DONE';
    log('migration', 'Simulated migration finished. Guest I/O integrity remains unverified.', run);
  }
  function release(run) {
    check(run.status === 'PAUSED', 'Wait for a held checkpoint.');
    run.hold_deadline = null;
    run.status = 'RESUMING';
    run.detail = 'Releasing the simulated issuing process.';
    log('daemon', 'SIGCONT simulated on the issuing host.', run);
    after(run, 1100, 'RESUMING', () => {
      run.status = 'DONE'; run.detail = 'Simulated checkpoint cycle complete.';
      if (run.guest_action !== 'none') log('guest','Simulated workload launch after release.',run);
      finishJob(run);
    });
  }
  function runAction(run) {
    check(run.status === 'PAUSED' && run.host_action_status === 'READY', 'The selected action can run once during a hold.');
    run.status = 'HOST_ACTION';
    run.host_action_status = 'RUNNING';
    run.detail = 'Simulating ' + config.actions[run.host_action].label + '.';
    log('action', run.detail, run);
    after(run, 1350, 'HOST_ACTION', () => {
      run.status = 'PAUSED'; run.host_action_status = 'DONE'; run.detail = 'Simulated action completed.';
      log('action',run.detail,run);
      if (run.automatic && run.auto_resume) release(run);
    });
  }
  function hold(run) {
    run.status = 'PAUSED';
    run.hold_deadline = now()/1000 + run.hold_seconds;
    run.detail = 'Simulated group stop confirmed on ' + run.host + '.';
    log('eBPF', run.phase + ' completed. SIGSTOP at issuing syscall exit (simulation).', run);
    log('daemon',run.detail,run);
    timer(() => {
      if (run !== current || !['PAUSED','HOST_ACTION'].includes(run.status)) return;
      run.status = 'FAILED'; run.hold_deadline = null; run.detail = 'Simulated hold expired. The process has been released.';
      if (run.host_action_status === 'RUNNING') run.host_action_status = 'INTERRUPTED';
      log('failure',run.detail,run); finishJob(run);
    }, run.hold_seconds*1000);
    if (run.automatic && run.host_action !== 'none') runAction(run);
    else if (run.automatic && run.auto_resume) release(run);
  }
  function integer(value,min,max,key) {
    const number = Number(value);
    check(value !== '' && Number.isInteger(number) && number >= min && number <= max, 'Invalid ' + key + '.');
    return number;
  }
  function startRun(body) {
    check(!active(current) && setup.status === 'READY', 'Prepare both simulated hosts before arming a new run.');
    const phase = config.phases.find(item => item.id === body.case);
    check(phase, 'Select a supported command.');
    const host = body.case === 5 ? body.target_host : phase.host;
    check(config.hosts[host], 'Select a trigger host.');
    integer(body.pid,2,2147483647,'issuer PID');
    const holdSeconds = integer(body.hold_seconds,5,600,'hold duration');
    integer(body.checkpoint_seconds,5,86400,'checkpoint wait');
    if (body.case === 5) {
      integer(body.selectors?.opcode,0,255,'opcode');
      check(['admin','io'].includes(body.selectors.queue), 'Select an NVMe queue.');
      for (const field of ['nsid','nsid_mask','cdw10','cdw10_mask','cdw11','cdw11_mask'])
        integer(body.selectors[field],0,0xffffffff,field);
    }
    const profile = config.actions[body.host_action];
    if (body.host_action !== 'none') {
      check(profile?.enabled && profile.host === host && profile.kind === 'host', 'Select an action for the trigger host.');
      if (profile.destructive) check(body.destructive_ack === profile.confirmation, 'Type the exact displayed namespace target.');
    }
    const run = {...clone(body), hold_seconds: holdSeconds, host, phase: phase.name, demo: true,
      id:'demo-'+(runs.length+1), created_at: now()/1000, status:'STARTING', detail:'Simulating hook attachment.',
      host_action_status:profile?'READY':'NONE', migration_started:false, migration_script_status:'NOT STARTED',
      migration_result:'NOT VERIFIED', hosts:clone(config.hosts)};
    runs.unshift(run); current = run;
    log('daemon',run.detail,run);
    after(run,900,'STARTING',()=>{run.status='ARMED';run.detail='Simulated hooks armed. Start live migration.';log('daemon',run.detail,run);});
    after(run, Number(body.checkpoint_seconds)*1000, 'ARMED', () => {
      run.status='FAILED';run.detail='Simulated checkpoint wait expired.';log('failure',run.detail,run);finishJob(run);
    });
    return run;
  }
  function jobRequest(key) {
    const profile=config.jobs[key];
    check(profile?.enabled && job?.status !== 'RUNNING','Wait for the active job.');
    if (profile.kind === 'migration') {
      const run=current;
      check(run?.status === 'ARMED' && !run.migration_started,'Arm a checkpoint before starting migration.');
      run.migration_started=true; run.migration_script_status='RUNNING';
      setup={status:'CONSUMED',detail:'Prepare hosts again before the next test.'};
      job={key,label:profile.label,status:'RUNNING'};
      log('migration','Simulated migration from '+config.hosts.source.address+' to '+config.hosts.destination.address+'.',run);
      after(run,1200,'ARMED',()=>hold(run));
    } else {
      check(!active(current),'Complete the current run before starting another job.');
      job={key,label:profile.label,status:'RUNNING'};
      log('job','Simulating '+profile.label+'.');
      timer(()=>{job.status='DONE';log('job','Simulated job complete.');},900);
    }
    return job;
  }
  function request(path,body) {
    if (path === '/api/info') return {mode:'demo'};
    if (path === '/api/config') return clone(config);
    if (path === '/api/state') return clone({mode:'demo',run:current,job,setup,history:runs,events:events.slice(-250)});
    if (path === '/api/hosts') {
      check(!active(current),'Finish the current run first.');
      for (const host of ['source','destination']) {
        const ip = body[host]?.address || '';
        check(/^\d{1,3}(\.\d{1,3}){3}$/.test(ip) && ip.split('.').every(part => Number(part) <= 255), 'Enter a valid example IPv4 address.');
        integer(body[host].ssh_port,1,65535,'SSH port');
      }
      for (const host of ['source','destination']) config.hosts[host] = {...config.hosts[host], ...body[host],cntlid:Number(body[host].cntlid)};
      setup={status:'IDLE',detail:'Example host settings saved for this tab.'}; return clone(config);
    }
    if (path === '/api/preflight' || path === '/api/prepare') {
      check(!active(current),'Finish the current run first.');
      const preparing = path === '/api/prepare';
      setup={status:preparing?'PREPARING':'CHECKING', detail:'Checking the simulated destination.'};
      log('setup',setup.detail);
      timer(()=>{setup.detail='Checking the simulated source.';log('setup',setup.detail);},400);
      timer(()=>{
        config.hosts.source.pid=12345;config.hosts.destination.pid=23456;
        setup={status:preparing?'READY':'CHECKED',detail:preparing?'Both simulated hosts are ready.':'Simulated checks passed. Prepare hosts next.'};log('setup',setup.detail);
      },850); return clone(setup);
    }
    if (path === '/api/runs') return clone(startRun(body));
    if (path === '/api/jobs') return clone(jobRequest(body.job));
    const match = path.match(/^\/api\/runs\/([^/]+)\/(action|resume|cancel|export)$/);
    check(match,'Unknown preview operation.');
    const run = runs.find(item=>item.id===match[1]);
    check(run,'Unknown preview run.');
    if (match[2] === 'export') return clone({run,events:events.filter(event=>event.run_id===run.id)});
    check(run===current && active(run),'This run is no longer active.');
    if (match[2] === 'action') runAction(run);
    if (match[2] === 'resume') release(run);
    if (match[2] === 'cancel') {
      run.status='CANCELLED';run.hold_deadline=null;run.detail='Simulated checkpoint disarmed and process released.';
      if (run.host_action_status==='RUNNING') run.host_action_status='INTERRUPTED';
      log('daemon',run.detail,run);finishJob(run);
    }
    return clone(run);
  }
  return request;
}
