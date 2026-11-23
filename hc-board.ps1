<#
.SYNOPSIS
  Live board of hc terminals as cards in three columns: NEEDS YOU | WORKING | DONE.

.DESCRIPTION
  Reloads whenever `hc events` reports a change (plus every -RefreshSeconds);
  redraws every second so each card's timer ticks. Columns come from the
  status agents report to hc:
    NEEDS YOU  blocked, error
    WORKING    working
    DONE       done, idle (done from before the board started shows as idle)
  Terminals that ended normally (exit 0, or killed) are hidden: press f or
  pass -ShowFinished. One that crashed (other exit code) goes to NEEDS YOU.
  Each card's timer is how long the agent has been in its current status
  (from hc's status_ms); finished terminals show time since they exited.
  Plain programs (shells, servers) report no status; they are hidden unless
  you press p or pass -ShowPlain, and then sit in DONE marked "plain".

  Agents idle longer than -IdleHideMinutes (20) are hidden too: press i.

  Keys: q quit   p plain terminals   f finished   i long-idle   r reload now

.EXAMPLE
  powershell -NoProfile -File .\hc-board.ps1
.EXAMPLE
  hc run --bg --outlive-parent --name board powershell -NoProfile -File .\hc-board.ps1
  hc attach board
#>
param(
    [switch]$ShowPlain,
    [switch]$ShowFinished,     # also show terminals that ended normally (exit 0)
    [int]$IdleHideMinutes = 20, # idle longer than this is hidden (key i shows them)
    [int]$TailLines = 3,        # last lines of each agent's output shown on its card
    [int]$TailSeconds = 2,      # how often working agents' output is re-read
    [switch]$Once,            # print the board once and exit (no live loop)
    [int]$RefreshSeconds = 15
)

$ErrorActionPreference = 'Stop'

$hc = (Get-Command hc -ErrorAction SilentlyContinue).Source
if (-not $hc) { $hc = Join-Path $env:LOCALAPPDATA 'Programs\herdr-core\hc.exe' }
if (-not (Test-Path $hc)) { throw "hc not found: install herdr-core first" }

$columns = @(
    @{ Title = 'NEEDS YOU'; Color = 'Red' },
    @{ Title = 'WORKING';   Color = 'Yellow' },
    @{ Title = 'DONE';      Color = 'Green' }
)

$script:ShowIdle = $false
# Agents never go from done back to idle themselves. The board does it: work
# finished before the board started counts as already seen and shows as idle.
$script:boardStartMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

# address -> @{ Status = <status name>; Ms = <status_ms>; Title = <task title> }
$script:stamps = @{}
$cardH = 4 + $TailLines   # lines per card

function Get-Terminals {
    $raw = (& $hc ls --all --json 2>$null) -join "`n"
    if ($LASTEXITCODE -or -not $raw.Trim()) { return $null }
    @(($raw | ConvertFrom-Json).terminals)
}

# `hc ls` gives status as a string, `hc get` as {app, state}.
function Get-StatusName($status) {
    if ($null -eq $status) { return $null }
    if ($status -is [string]) { return $status }
    if ($status.PSObject.Properties['state']) { return [string]$status.state }
    return [string]$status
}

# Agents put their current task in the terminal title ("Fix x | DragonGame").
# Drop the folder suffix and titles that are just the program's name.
function Get-TaskTitle([string]$title, $t) {
    if (-not $title) { return '' }
    $s = $title.Trim() -replace '^[^\p{L}\p{N}]+', ''
    $leaf = Split-Path -Leaf ([string]$t.cwd)
    if ($leaf) { $s = $s -replace (' \| ' + [regex]::Escape($leaf) + '$'), '' }
    if ($s -match '^(claude( code)?|codex|kimi( code)?|powershell.*|cmd(\.exe)?)$' -or $s -eq $t.agent -or $s -match '^[A-Za-z]:\\[^ ]*$') { return '' }
    $s
}

# The last message sent to the agent, read off its screen. Each agent echoes
# sent messages with a prompt mark and keeps its input box at the bottom:
#   Claude Code  "❯ text"; the input box is the ❯ line between the last two ─── rules
#   Codex        "› text"; the last › line is the input box
#   others       last "❯ text" / "› text" line
function Get-LastPrompt([string]$addr, [string]$app, $lines) {
    if ($null -eq $lines) { $lines = @(& $hc read $addr --lines 60 2>$null) }
    if (-not $lines) { return '' }
    $hit = ''
    if ($app -like 'claude*') {
        $rules = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^─{10,}') { $i } })
        $end = if ($rules.Count -ge 2) { $rules[-2] } else { $lines.Count }
        for ($i = $end - 1; $i -ge 0; $i--) { if ($lines[$i] -match '^❯ (.+)$') { $hit = $Matches[1]; break } }
    }
    elseif ($app -like 'codex*') {
        $sent = @($lines | ForEach-Object { if ($_ -match '^› (.+)$') { $Matches[1] } })
        if ($sent.Count -ge 2) { $hit = $sent[-2] }
    }
    else {
        for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match '^\s*[❯›] (.+)$') { $hit = $Matches[1]; break } }
    }
    $hit = $hit.Trim()
    # A task from another agent: <hc from="t7 dragon-claude">text</hc>
    if ($hit -match '^<hc from="(?:\S+ )?([^"]+)"[^>]*>(.*)$') { $hit = "от $($Matches[1]): " + ($Matches[2] -replace '</hc>\s*$', '') }
    $hit
}

# The agent's last $n output lines: everything above its input box, blanks
# and rules dropped. Input box: Claude Code — from the second-to-last ─── rule;
# Codex — the last "› " line; Kimi — the last ╭ box top.
function Get-ScreenTail($lines, [string]$app, [int]$n) {
    $lines = @($lines)
    if (-not $lines -or $n -le 0) { return @() }
    $end = $lines.Count
    if ($app -like 'claude*') {
        $rules = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^─{10,}') { $i } })
        if ($rules.Count -ge 2) { $end = $rules[-2] }
    }
    elseif ($app -like 'codex*') {
        for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match '^› ') { $end = $i; break } }
    }
    else {
        for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match '^\s*╭') { $end = $i; break } }
    }
    $out = New-Object Collections.Generic.List[string]
    for ($i = $end - 1; $i -ge 0 -and $out.Count -lt $n; $i--) {
        $s = ([string]$lines[$i]).Trim()
        if (-not $s -or $s -match '^[─━═\-_=·\s]+$' -or $s -match '^\(ctrl\+' -or $s -match '^⎿\s+Tip:') { continue }
        $out.Insert(0, $s)
    }
    , $out.ToArray()
}

# Re-read the screens of agents that are busy, so their cards follow along.
function Update-Tails($terms) {
    foreach ($t in @($terms)) {
        $s = $script:stamps[$t.address]
        if (-not $s -or $t.state -ne 'live') { continue }
        if ((Get-StatusName $t.status) -notin 'working', 'blocked', 'error') { continue }
        $lines = @(& $hc read $t.address --lines 0 2>$null)
        if ($lines) { $s.Tail = Get-ScreenTail $lines $s.App $TailLines }
    }
}

# hc get for each live agent: status_ms (timer) and title; ls has neither.
# The screen is read only when the agent's turn or status changes, or while
# its last message hasn't been found (it can scroll off during a long turn).
function Update-Stamps($terms) {
    $seen = @{}
    foreach ($t in @($terms)) {
        $seen[$t.address] = $true
        $name = Get-StatusName $t.status
        if ($t.state -ne 'live' -or -not $name) { $script:stamps.Remove($t.address); continue }
        try {
            $g = (& $hc get $t.address --json 2>$null) -join "`n" | ConvertFrom-Json
            if (-not $g) { continue }
            $old = $script:stamps[$t.address]
            $prompt = if ($old) { $old.Prompt } else { '' }
            $tail = if ($old) { $old.Tail } else { @() }
            $app = if ($g.status -and $g.status.PSObject.Properties['app']) { [string]$g.status.app } else { [string]$t.agent }
            if (-not $old -or $old.Turn -ne $t.turn -or $old.Status -ne $name -or -not $prompt) {
                $lines = @(& $hc read $t.address --lines 60 2>$null)
                $prompt = Get-LastPrompt $t.address $app $lines
                $tail = Get-ScreenTail $lines $app $TailLines
            }
            $script:stamps[$t.address] = @{
                Status = $name
                Turn   = $t.turn
                Ms     = if ($g.status_ms) { [int64]$g.status_ms } else { [int64]0 }
                Title  = Get-TaskTitle ([string]$g.title) $t
                Prompt = $prompt
                Tail   = $tail
                App    = $app
                Role   = if ($g.labels -and $g.labels.PSObject.Properties['role']) { [string]$g.labels.role } else { '' }
            }
        } catch {}
    }
    foreach ($k in @($script:stamps.Keys)) { if (-not $seen[$k]) { $script:stamps.Remove($k) } }
}

# Last message sent to the agent; the session title when none is on screen.
function Get-Task($t) {
    $s = $script:stamps[$t.address]
    if (-not $s) { return '' }
    if ($s.Prompt) { return $s.Prompt }
    $s.Title
}

function Test-Crashed($t) {
    $t.state -eq 'finished' -and $t.exit_code -ne 0 -and ([string]$t.reason) -notmatch 'kill'
}

# 0 needs you, 1 working, 2 done, -1 plain program (no agent status),
# -2 ended normally (hidden unless -ShowFinished)
function Get-ColumnIndex($t) {
    if ($t.state -eq 'finished') {
        if (Test-Crashed $t) { return 0 }
        return -2
    }
    switch (Get-StatusName $t.status) {
        'blocked' { return 0 }
        'error'   { return 0 }
        'working' { return 1 }
        'done'    { return 2 }
        'idle'    { return 2 }
    }
    return -1
}

# When the card's current status began.
function Get-Stamp($t) {
    $s = $script:stamps[$t.address]
    if ($s -and $s.Ms -and $s.Status -eq (Get-StatusName $t.status)) { return $s.Ms }
    foreach ($f in 'finished_ms', 'created_ms') {
        if ($t.PSObject.Properties[$f] -and $t.$f) { return [int64]$t.$f }
    }
    return [int64]0
}

# The status the board shows: done from before the board started becomes idle.
function Get-ShownStatus($t) {
    $name = Get-StatusName $t.status
    if ($name -eq 'done') {
        $since = Get-Stamp $t
        if ($since -and $since -lt $script:boardStartMs) { return 'idle' }
    }
    $name
}

function Format-Age([int64]$ms) {
    if (-not $ms) { return '' }
    $s = [int64][math]::Max(0, [math]::Floor(([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $ms) / 1000))
    if ($s -lt 60)    { return "${s}s" }
    if ($s -lt 3600)  { return '{0}m {1:00}s' -f [math]::Floor($s / 60), ($s % 60) }
    if ($s -lt 86400) { return '{0}h {1:00}m' -f [math]::Floor($s / 3600), [math]::Floor(($s % 3600) / 60) }
    return '{0}d {1}h' -f [math]::Floor($s / 86400), [math]::Floor(($s % 86400) / 3600)
}

# Console cells a char takes: CJK, Hangul and fullwidth forms take two.
function Get-CharWidth([char]$c) {
    $n = [int]$c
    if (($n -ge 0x1100 -and $n -le 0x115F) -or ($n -ge 0x2E80 -and $n -le 0xA4CF) -or
        ($n -ge 0xAC00 -and $n -le 0xD7A3) -or ($n -ge 0xF900 -and $n -le 0xFAFF) -or
        ($n -ge 0xFE30 -and $n -le 0xFE4F) -or ($n -ge 0xFF00 -and $n -le 0xFF60) -or
        ($n -ge 0xFFE0 -and $n -le 0xFFE6)) { return 2 }
    1
}

# Cut to $w console cells (with … when cut) and pad to exactly $w cells.
function Format-Cells([string]$s, [int]$w) {
    $total = 0
    foreach ($c in $s.ToCharArray()) { $total += Get-CharWidth $c }
    if ($total -gt $w) {
        $sb = New-Object Text.StringBuilder
        $used = 0
        foreach ($c in $s.ToCharArray()) {
            $cw = Get-CharWidth $c
            if ($used + $cw -gt $w - 1) { break }
            [void]$sb.Append($c); $used += $cw
        }
        $s = $sb.ToString() + '…'; $total = $used + 1
    }
    $s + (' ' * [math]::Max(0, $w - $total))
}

function Limit-End([string]$s, [int]$w) {
    if ($w -le 0) { return '' }
    if ($s.Length -le $w) { return $s }
    if ($w -eq 1) { return '…' }
    $s.Substring(0, $w - 1) + '…'
}

function Limit-Start([string]$s, [int]$w) {   # keep the end of a path
    if ($w -le 0) { return '' }
    if ($s.Length -le $w) { return $s }
    if ($w -eq 1) { return '…' }
    '…' + $s.Substring($s.Length - $w + 1)
}

function Get-StatusText($t, [bool]$plain) {
    if ($t.state -eq 'finished') {
        $why = if ($null -ne $t.exit_code) { "exit $($t.exit_code)" } elseif ($t.reason) { $t.reason } else { 'finished' }
        $what = if (Test-Crashed $t) { 'crashed' } else { 'finished' }
        return "$what · $why"
    }
    if ($plain) { return 'plain · running' }
    return Get-ShownStatus $t
}

# One card = $cardH lines of exactly $w chars: title (project - agent - role), task, status + timer.
function New-Card($t, [int]$w, [string]$color, [bool]$plain) {
    $in = $w - 4
    # Title: project - agent - role (role from hc label <t> role=..., when set).
    $st = $script:stamps[$t.address]
    $project = @(([string]$t.cwd) -split '[\\/]' | Where-Object { $_ })[-1]
    $agent = if ($t.agent) { ([string]$t.agent) -replace '-code$', '' -replace '\.exe$', '' } else { '?' }
    $who = (@($project, $agent) + @(if ($st -and $st.Role) { $st.Role })) -join ' - '
    $status = Get-StatusText $t $plain
    $age = if ($plain) { '' } else { Format-Age (Get-Stamp $t) }
    $c = if (Test-Crashed $t) { 'Red' }
         elseif ($t.state -eq 'finished' -or $plain) { 'DarkGray' }
         elseif ((Get-ShownStatus $t) -eq 'idle') { 'Cyan' }   # waiting for a task, unlike done
         else { $color }

    $top = '┌ ' + (Limit-End $who ($w - 4)) + ' '
    $top = $top + ('─' * [math]::Max(0, $w - 1 - $top.Length)) + '┐'
    $task = if ($plain) { '' } else { Get-Task $t }
    if (-not $task) { $task = '—' }
    $lines = @('│ ' + (Format-Cells $task $in) + ' │')
    # Last output lines, dimmer than the card, only while the agent is busy or
    # waiting for you (WORKING, NEEDS YOU); DONE cards are shorter without them.
    $busy = -not $plain -and $t.state -eq 'live' -and (Get-ShownStatus $t) -in 'working', 'blocked', 'error'
    $tail = if ($st -and $busy) { @($st.Tail) } else { @() }
    $tailRows = if ($busy) { $TailLines } else { 0 }
    # Status on the left, timer on the right.
    $timer = if ($age) { "⏱ $age" } else { '' }
    $left = Limit-End $status ([math]::Max(0, $in - $timer.Length - 1))
    $statusLine = '│ ' + $left.PadRight($in - $timer.Length) + $timer + ' │'
    $bottom = '└' + ('─' * ($w - 2)) + '┘'

    @($top) + $lines | ForEach-Object { @{ Text = $_; Color = $c } }
    for ($k = 0; $k -lt $tailRows; $k++) {
        $text = if ($k -lt $tail.Count) { '  ' + $tail[$k] } else { '' }
        # Inner: drawn in its own colour between the card's borders.
        @{ Text = '│ ' + (Format-Cells $text $in) + ' │'; Color = $c; Inner = $text; InnerColor = 'DarkGray' }
    }
    @($statusLine, $bottom) | ForEach-Object { @{ Text = $_; Color = $c } }
}

function Get-WindowSize {
    try { return @([Console]::WindowWidth, [Console]::WindowHeight) } catch { return @(120, 40) }
}

function Show-Board([bool]$live, $terms) {
    $width, $height = Get-WindowSize
    $cw = [math]::Max(16, [math]::Floor(($width - 1) / 3))    # column incl. 1-char gap
    $cardW = $cw - 1

    $buckets = @(@(), @(), @())
    $plainCount = 0
    $finishedCount = 0
    $idleCount = 0
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($terms) {
        foreach ($t in $terms) {
            $i = Get-ColumnIndex $t
            if ($i -eq 2 -and (Get-ShownStatus $t) -eq 'idle') {
                $since = Get-Stamp $t
                if ($since -and ($nowMs - $since) -gt $IdleHideMinutes * 60000) {
                    $idleCount++
                    if (-not $script:ShowIdle) { continue }
                }
            }
            if ($i -eq -2) {
                $finishedCount++
                if (-not $ShowFinished) { continue }
                $i = 2
            }
            elseif ($i -lt 0) {
                $plainCount++
                if (-not $ShowPlain) { continue }
                $i = 2
            }
            $buckets[$i] += , $t
        }
    }
    # Waiting longest first in NEEDS YOU; most recent first elsewhere.
    $buckets[0] = @($buckets[0] | Sort-Object { Get-Stamp $_ })
    $buckets[1] = @($buckets[1] | Sort-Object { Get-Stamp $_ } -Descending)
    # DONE: done on top, then idle, plain programs, finished; newest first within each.
    $rank = { if ($_.state -eq 'finished') { 3 } else { switch (Get-ShownStatus $_) { 'done' { 0 } 'idle' { 1 } default { 2 } } } }
    $buckets[2] = @($buckets[2] | Sort-Object @{ e = $rank }, @{ e = { Get-Stamp $_ }; Descending = $true })

    # Title, blank, column headers, footer; leave the last row empty to avoid scrolling.
    $cardRows = [math]::Max($cardH, $height - 5)
    $colLines = @()
    for ($i = 0; $i -lt 3; $i++) {
        $col = $columns[$i]
        $items = $buckets[$i]
        $lines = @(@{ Text = "$($col.Title) ($($items.Count))"; Color = $col.Color })
        # Cards differ in height: add them while they fit, keeping a row for "+N more".
        $fit = 0
        $used = 0
        for ($k = 0; $k -lt $items.Count; $k++) {
            $plain = (Get-ColumnIndex $items[$k]) -eq -1
            $card = @(New-Card $items[$k] $cardW $col.Color $plain)
            $room = if ($k -eq $items.Count - 1) { $cardRows } else { $cardRows - 1 }
            if ($used + $card.Count -gt $room) { break }
            $lines += $card
            $used += $card.Count
            $fit++
        }
        if ($items.Count -gt $fit) { $lines += @{ Text = "  +$($items.Count - $fit) more"; Color = 'DarkGray' } }
        if ($items.Count -eq 0) { $lines += @{ Text = '  —'; Color = 'DarkGray' } }
        $colLines += , $lines
    }

    $rows = ($colLines | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
    $full = $cw * 3

    if ($live) { [Console]::SetCursorPosition(0, 0) }
    $hidden = if ($ShowPlain) { "plain shown" } else { "plain hidden: $plainCount" }
    $hidden += if ($ShowFinished) { " · finished shown" } else { " · finished hidden: $finishedCount" }
    $hidden += if ($script:ShowIdle) { " · idle shown" } else { " · idle >${IdleHideMinutes}m hidden: $idleCount" }
    $title = "hc board · $(Get-Date -Format 'HH:mm:ss') · $hidden"
    if ($live) { $title += '   [q] quit  [p] plain  [f] finished  [i] idle  [r] reload' }
    if ($null -eq $terms) { $title += '   (hc core not answering)' }
    Write-Host (Limit-End $title $full).PadRight($full) -ForegroundColor White
    Write-Host (' ' * $full)

    $drawn = 2
    for ($r = 0; $r -lt $rows; $r++) {
        for ($i = 0; $i -lt 3; $i++) {
            $cell = if ($r -lt $colLines[$i].Count) { $colLines[$i][$r] } else { @{ Text = ''; Color = 'Gray' } }
            if ($cell.ContainsKey('Inner')) {
                Write-Host '│ ' -ForegroundColor $cell.Color -NoNewline
                Write-Host (Format-Cells $cell.Inner ($cardW - 4)) -ForegroundColor $cell.InnerColor -NoNewline
                Write-Host ' │ ' -ForegroundColor $cell.Color -NoNewline
            }
            else {
                Write-Host ((Format-Cells $cell.Text $cardW) + ' ') -ForegroundColor $cell.Color -NoNewline
            }
        }
        Write-Host ''
        $drawn++
    }
    Write-Host (' ' * $full)   # spaces, not '': this row must overwrite the last frame
    Write-Host (Limit-End 'take one over: hc attach <name>   (ctrl+\ detaches)' $full).PadRight($full) -ForegroundColor DarkGray
    $drawn += 2

    if ($live) {
        for (; $drawn -lt $height - 1; $drawn++) { Write-Host (' ' * $full) }
    }
}

$oldEnc = [Console]::OutputEncoding
[Console]::OutputEncoding = [Text.Encoding]::UTF8

if ($Once) {
    try {
        $terms = Get-Terminals
        Update-Stamps $terms
        Show-Board $false $terms
    } finally { [Console]::OutputEncoding = $oldEnc }
    return
}

function Start-Events {
    $psi = New-Object Diagnostics.ProcessStartInfo $hc, 'events --json'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    [Diagnostics.Process]::Start($psi)
}

$proc = $null; $read = $null
$lastStart = [datetime]::MinValue
$lastLoad = [datetime]::MinValue
$lastDraw = [datetime]::MinValue
$lastTail = [datetime]::MinValue
$size = ''
$reload = $true      # fetch terminals from hc
$fullStamps = $true  # re-read every status_ms, not just changed ones
$redraw = $true
$terms = $null
$quit = $false
$oldCursor = $true
try { $oldCursor = [Console]::CursorVisible } catch {}

try {
    try { [Console]::CursorVisible = $false } catch {}
    Clear-Host
    while (-not $quit) {
        # Event stream: (re)start it, at most every 5 s if it keeps dying.
        if ((-not $proc -or $proc.HasExited) -and ((Get-Date) - $lastStart).TotalSeconds -ge 5) {
            if ($proc) { $proc.Dispose() }
            $lastStart = Get-Date
            try { $proc = Start-Events; $read = $proc.StandardOutput.ReadLineAsync() } catch { $proc = $null; $read = $null }
            $reload = $true
        }
        while ($read -and $read.IsCompleted) {
            if ($null -eq $read.Result) { $read = $null; break }    # stream ended; restarted above
            $reload = $true
            $read = $proc.StandardOutput.ReadLineAsync()
        }

        while ([Console]::KeyAvailable) {
            switch ([Console]::ReadKey($true).KeyChar) {
                'q' { $quit = $true }
                'p' { $ShowPlain = -not $ShowPlain; $redraw = $true }
                'f' { $ShowFinished = -not $ShowFinished; $redraw = $true }
                'i' { $script:ShowIdle = -not $script:ShowIdle; Clear-Host; $redraw = $true }
                'r' { Clear-Host; $reload = $true; $fullStamps = $true }
            }
        }

        $w, $h = Get-WindowSize
        if ("${w}x$h" -ne $size) { $size = "${w}x$h"; Clear-Host; $redraw = $true }
        if (((Get-Date) - $lastLoad).TotalSeconds -ge $RefreshSeconds) { $reload = $true; $fullStamps = $true }
        if (((Get-Date) - $lastDraw).TotalSeconds -ge 1) { $redraw = $true }   # tick the timers

        if ($reload -and -not $quit) {
            $terms = Get-Terminals
            Update-Stamps $terms
            $lastLoad = Get-Date
            $reload = $false; $fullStamps = $false; $redraw = $true
        }
        if ($terms -and ((Get-Date) - $lastTail).TotalSeconds -ge $TailSeconds) {
            Update-Tails $terms
            $lastTail = Get-Date
            $redraw = $true
        }
        if ($redraw -and -not $quit) {
            Show-Board $true $terms
            $lastDraw = Get-Date
            $redraw = $false
        }
        Start-Sleep -Milliseconds 150
    }
}
finally {
    if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch {} }
    try { [Console]::CursorVisible = $oldCursor } catch {}
    [Console]::OutputEncoding = $oldEnc
    Clear-Host
}
