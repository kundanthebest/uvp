#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build a standalone Windows demo from the same UI that the Linux controller serves.
set -euo pipefail
demo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$demo")
output="$demo/uvp-demo.html"
staged=$(mktemp -- "$demo/.uvp-demo.XXXXXXXX")
trap 'rm -f -- "$staged"' EXIT

jq -rj \
    --rawfile page "$root/web/index.html" \
    --rawfile css "$root/web/style.css" \
    --rawfile js "$root/web/app.js" \
    --rawfile adapter "$demo/adapter.js" \
    -f /dev/stdin "$root/config/demo.json" > "$staged" <<'JQ'
# Fail visibly if a template changes and an offline substitution needs updating.
def replace_once($old; $new):
    split($old) | if length == 2 then join($new) else error("Missing or repeated template fragment: " + $old) end;
def fields($keys): with_entries(select(.key as $key | $keys | index($key)));
def phase($id; $name; $host; $symbol): {$id,$name,$host,$symbol};
{
    mode: "demo", require_prepare: true,
    hosts: (.hosts | map_values(fields(["address","user","controller","cntlid","ssh_port","ssh_target"]))),
    jobs: (.jobs | map_values(fields(["label","kind","host","enabled"]))),
    actions: (.actions | map_values(fields(["label","kind","host","enabled","description","argv","destructive","controller","nsid","confirmation"]))),
    phases: [
        phase(1; "Suspend complete"; "source"; "nvmevf_cmd_suspend_device"),
        phase(2; "Get controller state complete"; "source"; "nvmevf_cmd_get_ctrl_state"),
        phase(3; "Set controller state complete"; "destination"; "nvmevf_cmd_set_ctrl_state"),
        phase(4; "Resume complete"; "destination"; "nvmevf_cmd_resume_device"),
        phase(5; "Custom NVMe command"; "Selected host"; "Synchronous NVMe syscall")
    ]
} | @json | split("<") | join("\\u003c") as $config
| ($js
    | sub("async function api\\(path,body\\)\\{.*?\\}\\nasync function action"; "async function api(path,body){return previewRequest(path,body);}\nasync function action"; "s")
    | replace_once("try{token=sessionStorage.getItem('uvp-token')||'';}catch(_){}"; "token='uvp-demo';")
    | replace_once("try{sessionStorage.setItem('uvp-token',token);}catch(_){}"; "")
    | replace_once("await fetch('/api/info').then(r=>r.json())"; "await api('/api/info')")
    | replace_once("connected?'Controller connected'"; "connected?'Offline simulation ready'")
) as $offline
| if (($offline | contains("fetch(")) or (($offline + $adapter) | test("</script"; "i"))) then
      error("Unexpected network call or script terminator in offline UI")
  else . end
| $page
| replace_once("<noscript><p><a href=\"/forms\">Open the UVP dashboard for browsers without JavaScript</a></p></noscript>"; "<noscript><p>The offline simulator requires JavaScript. To run UVP without browser scripts, open the Linux controller's /forms page.</p></noscript>")
| replace_once("<title>UVP — NVMe fault orchestration</title>"; "<title>UVP — Offline demo</title><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; connect-src 'none'; base-uri 'none'; form-action 'none'\">")
| replace_once("<link rel=\"stylesheet\" href=\"/style.css\"><script defer src=\"/app.js\"></script>"; "<style>" + $css + "\n#auth-toggle {display:none}</style>")
| replace_once("href=\"/\" aria-label=\"UVP home\""; "href=\"#control-panel\" aria-label=\"UVP home\"")
| replace_once("Open this console through an SSH tunnel. Your Linux servers do the work."; "This demo runs in your browser. Open the full project to connect your Linux servers.")
| replace_once("DEMO ENVIRONMENT"; "OFFLINE DEMO")
| replace_once("Explore the complete workflow. No devices, processes, or migration jobs are changed."; "Use the example IPs, click Prepare hosts, then load the hooks and start a simulated migration. Run history lasts until you close or refresh this tab.")
| replace_once("PERSISTENT LOG"; "THIS TAB")
| replace_once("Linux execution · Windows browser control"; "Offline browser simulation")
| replace_once("</body>"; "<script>\n" + $adapter + "\nconst previewRequest = createPreview(" + $config + ");\n" + $offline + "\n</script>\n</body>")
JQ
chmod 0644 "$staged"
mv -- "$staged" "$output"
