# Adapt only the three UVP-supplied helpers from the previous installation.
# Preserve operator programs and arguments, including paths passed as data.
def old_helper: type=="string" and startswith("/") and
  test("/scripts/host-(bridge|action|preflight)\\.py\\z");
def adapt_argv:
  if type!="array" then .
  else . as $args | index("/usr/bin/python3") as $i |
    if $i != null and ($args[$i+1] | old_helper) and
      ($i==0 or ($args[0]=="/usr/bin/sudo" and all($args[1:$i][]; .=="-n" or .=="--")))
    then $args[:$i] + [($args[$i+1]|sub("\\.py\\z";".sh"))] + $args[$i+2:]
    else . end end;
def adapt_legacy:
  .hosts |= with_entries(.value |=
    if (.bridge|type)=="string" and (.bridge|startswith("/") and test("/scripts/host-bridge\\.py\\z"))
    then .bridge |= sub("\\.py\\z";".sh") else . end) |
  reduce ["actions","jobs"][] as $key (.; if .[$key] then
    .[$key] |= with_entries(.value |= if has("argv") then .argv |= adapt_argv else . end)
    else . end);
