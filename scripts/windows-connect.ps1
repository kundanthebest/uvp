param(
    [Parameter(Mandatory=$true)][string]$Controller,
    [int]$LocalPort = 8000,
    [int]$RemotePort = 8000
)
$ErrorActionPreference = 'Stop'
if ($Controller -notmatch '^[a-zA-Z0-9_.-]+@[a-zA-Z0-9_.-]+$') {
    throw 'Use Controller in user@hostname or user@IPv4 form.'
}
if ($LocalPort -lt 1024 -or $LocalPort -gt 65535 -or $RemotePort -lt 1 -or $RemotePort -gt 65535) {
    throw 'Invalid port.'
}
if ($LocalPort -ne $RemotePort) {
    throw 'Use matching local and remote ports because the controller checks the HTTP Host header. Start the controller with --port if needed.'
}
Write-Host "Open http://127.0.0.1:$LocalPort in Edge or Chrome and use the token printed by the Linux controller."
Write-Host 'Keep this SSH tunnel open. Ctrl+C closes the tunnel; it does not cancel a running UVP test.'
& ssh -N -T -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -L "${LocalPort}:127.0.0.1:${RemotePort}" $Controller
exit $LASTEXITCODE
