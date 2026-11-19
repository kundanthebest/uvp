# SPDX-License-Identifier: GPL-2.0-only
def e: (. // "" | tostring | @html);
def input($name;$label;$value):
  "<label>\($label|e)<input name=\"\($name|e)\" value=\"\($value|e)\"></label>";
def option($value;$label):
  "<option value=\"\($value|e)\">\($label|e)</option>";
def hidden($name;$value):
  "<input type=hidden name=\"\($name|e)\" value=\"\($value|e)\">";
def button($op;$label;$enabled):
  "<button name=op value=\"\($op|e)\"\(if $enabled then "" else " disabled" end)>\($label|e)</button>";
def controls($contents):
  "<form method=post action=/forms class=buttons>\($contents)</form>";
def enumerate_profiles($kind):
  ([$cfg.actions|to_entries[]|select(.value.enabled and .value.kind==$kind)
    |option(.key;("\(.value.host) · \(.value.label)" + (if .value.destructive then " · "+(.value.confirmation // ((.value.controller|tostring)+":"+(.value.nsid|tostring))) else "" end)))]|join(""));
def host($s;$label):
  $cfg.hosts[$s] as $h |
  "<fieldset><legend>\($label|e)</legend>" +
  input($s+"_address";"Linux server IP";$h.address) +
  "<div class=pair>" + input($s+"_user";"SSH user";$h.user) + input($s+"_ssh_port";"Port";$h.ssh_port) + "</div>" +
  "<div class=pair>" + input($s+"_controller";"NVMe controller";$h.controller) + input($s+"_cntlid";"CNTLID";$h.cntlid) + "</div>" +
  hidden($s+"_pid";($h.pid // 0)) + "</fieldset>";
def export($id):
  "<form method=post action=/forms/export target=_blank>" + hidden("id";$id) + "<button>Export JSON</button></form>";
. as $state | (.run // {}) as $run | (.setup.status // "IDLE") as $setup |
 .job.status as $job |
 (["STARTING","ARMED","PAUSED","HOST_ACTION","RESUMING","RELEASED","CANCELLING"] | index($run.status)) as $active |
 (($active==null) and $job!="RUNNING" and ($setup!="CHECKING" and $setup!="PREPARING")) as $idle |
 ([$cfg.jobs|to_entries[]|select(.value.enabled and .value.kind=="migration")|.key][0]) as $migration |
 "<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content=\"width=device-width, initial-scale=1\"><title>UVP · NVMe migration</title><link rel=stylesheet href=/forms.css></head><body>" +
 "<header><div class=wrap><a class=brand href=/forms>UVP</a><nav><a href=#setup>Hosts</a><a href=#recipe>Checkpoint</a><a href=#events>Events</a></nav></div></header><main class=wrap>" +
 "<div class=title><div><p class=eyebrow>NVMe validation</p><h1>Live migration</h1></div><span class=mode>\($cfg.mode|e) mode</span></div>" +
 (if $cfg.mode=="demo" then "<p class=notice>This session simulates both Linux hosts and all NVMe commands.</p>" else "" end) +
 (if $error!="" then "<p class=error role=alert>\($error|e)</p>" else "" end) +
 "<section class=status><div><p class=eyebrow>Current run</p><h2>\(($run.status // .setup.status // "IDLE")|e)</h2><p>\(($run.detail // .setup.detail // "Configure and prepare both Linux hosts.")|e)</p></div><a class=refresh href=/forms>Refresh status</a></section>" +
 "<div class=grid><section id=setup><h2>Migration hosts</h2><form method=post action=/forms><div class=hosts>" + host("source";"Source PC") + host("destination";"Destination PC") +
 "</div><div class=buttons>" + button("hosts";"Save hosts";$idle) + button("preflight";"Check readiness";$idle) + button("prepare";"Prepare hosts";$idle) + "</div></form>" +
 "<p class=hint>Host preparation: \($setup|e). The destination starts first.</p></section>" +
 "<section id=recipe><h2>Checkpoint and action</h2><form method=post action=/forms><label>NVMe command<select name=phase>" +
 ([$cfg.phases[]|option(.id;("\(.name)" + (if .id==5 then "" else " · "+.host end)))]|join("")) +
 "</select></label><label>Action while stopped<select name=host_action>" + option("none";"No action") + enumerate_profiles("host") + "</select></label>" +
 "<details><summary>Command filters and run options</summary><label>Host for custom opcode<select name=target_host>" + option("source";"Source PC")+option("destination";"Destination PC")+"</select></label>" +
 input("pid";"Issuer PID override (optional)";"") + "<div class=pair>" + input("opcode";"Custom opcode";"0x06") +
 "<label>Queue<select name=queue>" + option("admin";"Admin") + option("io";"I/O") + "</select></label></div>" +
 (["nsid","cdw10","cdw11"]|map(. as $f|"<div class=pair>"+ input($f;($f|ascii_upcase);0)+input($f+"_mask";"Match mask";0)+"</div>")|join("")) +
 "<div class=pair>"+input("hold_seconds";"Hold timeout (s)";120)+input("checkpoint_seconds";"Checkpoint timeout (s)";300)+"</div>" +
 "<label>Action after release<select name=guest_action>"+option("none";"No action")+enumerate_profiles("guest")+"</select></label>" +
 input("destructive_ack";"Exact target for namespace deletion";"") + "</details>" +
 "<label class=tick><input type=checkbox name=automatic checked>Run the selected action automatically</label><label class=tick><input type=checkbox name=auto_resume checked>Release after the action succeeds</label>" +
 button("arm";"Load eBPF hook and UVP daemon";($idle and (($cfg.require_prepare|not) or $setup=="READY"))) + "</form>" +
 controls(hidden("id";$run.id)+hidden("job";$migration)+button("migrate";"Start live migration";($migration!=null and $run.status=="ARMED" and ($run.migration_started|not) and $job!="RUNNING"))) + "</section></div>" +
 "<section><h2>Run controls</h2><p>Checkpoint: \(($run.phase // "—")|e) · Host action: \(($run.host_action_status // "—")|e) · Migration script: \(($run.migration_script_status // "—")|e)</p>" +
 controls(hidden("id";$run.id) + button("action";"Run selected action";($run.status=="PAUSED" and $run.host_action_status=="READY"))+button("resume";"Release process";($run.status=="PAUSED"))+button("cancel";"Disarm checkpoint";($active!=null and $run.status!="CANCELLING"))) +
 (if $run.id then export($run.id) else "" end) +
 "<details><summary>Additional jobs</summary><form method=post action=/forms><label>Configured job<select name=job>" +
 ([$cfg.jobs|to_entries[]|select(.value.enabled and .value.kind!="migration")|option(.key;.value.label)]|join(""))+"</select></label>"+button("job";"Run job";$idle)+"</form></details></section>" +
 "<section id=events><div class=sectionhead><h2>Event log</h2><a href=/forms#events>Refresh</a></div><ol class=events>" +
 ([.events[-60:][]? | "<li><time>\((.time|floor|todateiso8601)|e)</time><strong>\(.kind|e)</strong><span>\(.message|e)</span></li>"] | if length==0 then "<li>Events appear here when a run starts.</li>" else reverse|join("") end) +
 "</ol></section><details class=history><summary>Run history</summary>" +
 ([.history[]? | "<div class=entry><span>\(.id|e) · \(.phase|e) · \(.status|e)</span>"+export(.id)+"</div>"]|join("")) +
 "</details></main></body></html>"
