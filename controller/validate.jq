# SPDX-License-Identifier: GPL-2.0-only
def invalid($s): error("400 " + $s);
def conflict($s): error("409 " + $s);
def field($o; $k; $default): if $o|has($k) then $o[$k] else $default end;

def uint($v; $min; $max; $label):
  (if $v|type == "number" then $v
   elif ($v|type) == "string" and ($v|test("^[0-9]+\\z")) then ($v|tonumber)
   elif ($v|type) == "string" and ($v|test("^0x[0-9A-Fa-f]+\\z")) then
     reduce ($v[2:]|ascii_downcase|explode[]) as $c (0; . * 16 + (if $c <= 57 then $c-48 else $c-87 end))
   else null end) as $n
  | if ($n|type) == "number" and $n >= $min and $n <= $max and ($n|floor) == $n then $n
    else invalid($label + ": expected an integer from " + ($min|tostring) + " to " + ($max|tostring)) end;

def active:
  . as $s | ["STARTING","ARMED","PAUSED","HOST_ACTION","RESUMING","RELEASED","CANCELLING"] | index($s) != null;
def ready_for_change:
  if .closing or (.run.status|active) or .job.status == "RUNNING" or
     (.setup.status == "PREPARING" or .setup.status == "CHECKING")
  then conflict("Wait for the active operation or disarm the checkpoint") else . end;

def phases: [
  {id:1,name:"Suspend complete",host:"source",symbol:"nvmevf_cmd_suspend_device"},
  {id:2,name:"Get controller state complete",host:"source",symbol:"nvmevf_cmd_get_ctrl_state"},
  {id:3,name:"Set controller state complete",host:"destination",symbol:"nvmevf_cmd_set_ctrl_state"},
  {id:4,name:"Controller resume complete",host:"destination",symbol:"nvmevf_cmd_resume_device"},
  {id:5,name:"Custom NVMe command",host:"source",symbol:""}
];
def only($keys): with_entries(select(.key as $k|$keys|index($k)));
def public_hosts: with_entries(.value |= only(["transport","address","user","ssh_target","ssh_port","pid","controller","cntlid"]));
def public_config: {mode,require_prepare:(.config.require_prepare == true),phases:phases,
  hosts:(.config.hosts|public_hosts),
  actions:((.config.actions // {})|with_entries(.value |= only(["label","kind","host","enabled","description","argv","destructive","confirmation","controller","nsid"]))),
  jobs:((.config.jobs // {})|with_entries(.value |= only(["label","kind","host","enabled"])))};

def argv_ok:
  type == "array" and length >= 1 and length <= 64 and
  all(.[]; type == "string" and length < 4096 and (explode|all(. != 0 and . != 10 and . != 13))) and
  (.[0]|startswith("/"));
def profile($cfg; $key; $kind; $side):
  if $key == "none" then null
  elif ($key|type) != "string" then invalid("Invalid action profile")
  else $cfg.actions[$key] as $p | if $p.enabled != true or $p.kind != $kind or $p.host != $side
       then invalid("Choose an enabled " + $kind + " action for the checkpoint host")
       elif ($p.argv|argv_ok|not) then invalid("Invalid configured action arguments") else $p end end;

def valid_controller: type == "string" and test("^/dev/nvme[0-9]+\\z");

# inet_pton in the companion program checks and canonicalizes the two literal IPs.
def updated_hosts($req; $src; $dst):
  ready_for_change | . as $s |
  if ($req|keys) != ["destination","source"] then invalid("Supply source and destination host settings") else . end |
  reduce ["source","destination"][] as $side (.config.hosts;
    $req[$side] as $v | .[$side] as $old |
    if ($v|type) != "object" or (($v|keys) - ["address","user","ssh_port","pid","controller","cntlid"]|length) != 0
    then invalid("Unsupported host field") else . end |
    field($v;"user";"uvp") as $user |
    field($v;"controller";$old.controller // "/dev/nvme0") as $ctrl |
    if ($user|type) != "string" or ($user|test("^[a-z_][a-z0-9_-]{0,31}\\z")|not)
    then invalid("Invalid SSH username") elif ($ctrl|valid_controller|not) then invalid("Invalid NVMe controller") else . end |
    (if $side == "source" then $src else $dst end) as $addr |
    .[$side] += {user:$user,address:$addr,ssh_target:($user+"@"+$addr),controller:$ctrl,
      pid:uint((if $v.pid=="" then 0 else field($v;"pid";0) end);0;2147483647;"PID"), ssh_port:uint(field($v;"ssh_port";22);1;65535;"SSH port"),
      cntlid:uint(field($v;"cntlid";1);0;65535;"CNTLID")} |
    if $s.mode=="hardware" then .[$side].transport="ssh" else . end);

def selectors($s):
  if ($s|type) != "object" then invalid("Selectors must be an object") else . end |
  field($s;"queue";"admin") as $q |
  if $q != "admin" and $q != "io" then invalid("Queue must be admin or io") else . end |
  reduce ["nsid","nsid_mask","cdw10","cdw10_mask","cdw11","cdw11_mask"][] as $k
    ({opcode:uint($s.opcode;0;255;"opcode"),queue:$q}; .[$k] = uint(field($s;$k;0);0;4294967295;$k));

def new_run($req; $id):
  ready_for_change |
  if .config.require_prepare and .setup.status != "READY" then conflict("Prepare both hosts before loading hooks") else . end |
  .config as $cfg | uint(field($req;"case";1);1;5;"case") as $case | phases[$case-1] as $phase |
  (if $case == 5 then field($req;"target_host";"source") else $phase.host end) as $side |
  if $side != "source" and $side != "destination" then invalid("Invalid trigger host") else . end |
  $cfg.hosts[$side] as $h |
  uint(field($req;"pid";$h.pid);2;2147483647;"Issuer PID") as $pid |
  field($req;"controller";$h.controller) as $ctrl |
  uint(field($req;"cntlid";$h.cntlid // 1);0;65535;"CNTLID") as $cntlid |
  if ($ctrl|valid_controller|not) then invalid("Expected an NVMe controller such as /dev/nvme0")
  elif $case != 5 and $cfg.require_prepare and ($pid != $h.pid or $ctrl != $h.controller or $cntlid != $h.cntlid)
  then conflict("Save device settings and prepare hosts before changing the migration hook target") else . end |
  field($req;"automatic";false) as $automatic | field($req;"auto_resume";true) as $resume |
  if ($automatic|type) != "boolean" or ($resume|type) != "boolean" then invalid("Automatic controls must be booleans") else . end |
  field($req;"host_action";"none") as $hk | field($req;"guest_action";"none") as $gk |
  profile($cfg;$hk;"host";$side) as $hp | profile($cfg;$gk;"guest";$side) as $gp |
  if $hp.destructive then
    ($hp.confirmation // (($hp.controller // $ctrl) + ":" + ($hp.nsid|tostring))) as $ack |
    if $ack == "" or $req.destructive_ack != $ack then invalid("Confirm the exact destructive action target: " + $ack) else . end
  else . end |
  ($h.symbols[($case|tostring)] // $phase.symbol) as $symbol |
  if ($symbol|type) != "string" or ($case != 5 and $symbol == "") or ($symbol|test("^[A-Za-z0-9_.$]*\\z")|not)
  then invalid("Invalid configured wrapper symbol") else . end |
  {id:$id,status:"STARTING",case:$case,phase:$phase.name,host:$side,pid:$pid,controller:$ctrl,cntlid:$cntlid,symbol:$symbol,
    hold_seconds:uint(field($req;"hold_seconds";120);5;600;"hold_seconds"),
    checkpoint_seconds:uint(field($req;"checkpoint_seconds";300);5;86400;"checkpoint_seconds"),
    selectors:(if $case==5 then selectors(field($req;"selectors";{})) else {} end),
    host_action:$hk,guest_action:$gk,automatic:$automatic,auto_resume:$resume,auto_action_requested:false,auto_resume_requested:false,
    host_action_status:(if $hp then "READY" else "NONE" end),guest_action_status:(if $gp then "QUEUED" else "NONE" end),
    created_at:now,hold_deadline:null,detail:"Starting checkpoint daemon",demo:(.mode=="demo"),migration_started:false,
    migration_script_status:"NOT STARTED",migration_result:"NOT VERIFIED",hosts:($cfg.hosts|public_hosts)};

def new_job($req; $id):
  if .closing or .setup.status == "PREPARING" or .setup.status == "CHECKING" or .job.status == "RUNNING"
  then conflict("Wait for the current setup or job") else . end |
  $req.job as $key |
  if ($key|type) != "string" then invalid("Invalid job") else . end |
  .config.jobs[$key] as $p |
  if $p.enabled != true then invalid("Job is missing or disabled")
  elif ($p.argv|argv_ok|not) then invalid("Invalid configured job arguments")
  elif $p.kind == "migration" and ($req|has("run_id")) and $req.run_id != .run.id then conflict("Migration belongs to a different run")
  elif $p.kind == "migration" and (.run.status != "ARMED" or .run.migration_started)
  then conflict("Migration requires an ARMED checkpoint and can start once per run")
  elif $p.kind != "migration" and (.run.status|active) then conflict("This job requires an idle checkpoint")
  else {id:$id,key:$key,label:$p.label,kind:$p.kind,status:"RUNNING",run_id:.run.id} end;

def controlled($id; $command):
  if .closing or .run.id != $id or (.run.status|active|not) then conflict("Run is stale or no longer active") else . end |
  .run |
  if $command == "cancel" then
    if .status == "CANCELLING" then conflict("Already cancelling") else . + {status:"CANCELLING",detail:"Cancelling checkpoint; migration itself is not cancelled"} end
  elif .status != "PAUSED" then conflict("Control requires a held checkpoint")
  elif $command == "resume" then . + {status:"RESUMING"}
  elif $command == "action" and .host_action_status == "READY" then . + {status:"HOST_ACTION",host_action_status:"RUNNING"}
  else conflict("Host action already used or not selected") end;
