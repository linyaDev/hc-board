# Usage: hc-agent.ps1 <name> <cwd> <command> [args...]
#
# Attaches this console to the hc terminal <name>, starting it first if it is
# not running. Started with --outlive-parent, so closing the console (or VS
# Code) leaves the agent running; the next call attaches to it again.
# ctrl+\ detaches.
#   hc-agent.ps1 --role <title> <name> <cwd> ...   also sets the label role=<title>,
#   which the board shows on the card (hc label <name> role=... changes it later).
$ErrorActionPreference = 'Stop'
$a = @($args)
$role = ''
if ($a.Count -ge 2 -and $a[0] -eq '--role') { $role = [string]$a[1]; $a = @($a[2..($a.Count - 1)]) }
if ($a.Count -lt 3) { throw 'usage: hc-agent.ps1 [--role <title>] <name> <cwd> <command> [args...]' }
$name = [string]$a[0]
$cwd  = [string]$a[1]
$cmd  = @($a[2..($a.Count - 1)] | ForEach-Object { [string]$_ })

$hc = (Get-Command hc -ErrorAction SilentlyContinue).Source
if (-not $hc) { $hc = Join-Path $env:LOCALAPPDATA 'Programs\herdr-core\hc.exe' }
if (-not (Test-Path $hc)) { throw "hc not found: install herdr-core first" }
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$all  = @(((& $hc ls --all --json) -join "`n" | ConvertFrom-Json).terminals)
$mine = @($all | Where-Object { $_.name -eq $name })
$live = $mine | Where-Object { $_.state -eq 'live' } | Select-Object -First 1

if (-not $live) {
    # A finished terminal would still hold the name.
    foreach ($t in $mine) { & $hc rm $t.address 2>$null | Out-Null }
    $labels = if ($role) { @('--label', "role=$role") } else { @() }
    & $hc run --bg --outlive-parent --name $name @labels --cwd $cwd -- @cmd | Out-Null
    if ($LASTEXITCODE) { throw "hc could not start '$name'" }
}
elseif ($role) { & $hc label $name "role=$role" | Out-Null }
& $hc attach $name
