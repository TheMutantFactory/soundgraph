# The gate, on one screen: which stage it is on, how long, the check count inside a
# suite, and the verdict. Reads run/gate-status, which tools/pre-push.sh rewrites at
# every step, and redraws once a second. Opened in its own window by watch-gate.bat;
# run it here with -Once to draw a single frame and leave, which is how it is tested.
#
# It knows nothing the file does not say. A gate older than the file leaves none, and
# the window says so rather than guessing.

param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [switch]$Once
)

$statusPath = Join-Path $Root 'run\gate-status'

# The suites print one "  ok   ..." line per check; counting them is the progress bar.
function Read-Shared([string]$path) {
    # Shared read: the gate is still writing the suite log this counts.
    try {
        $stream = New-Object IO.FileStream($path, 'Open', 'Read', 'ReadWrite')
        try {
            $reader = New-Object IO.StreamReader($stream)
            return $reader.ReadToEnd()
        } finally { $stream.Dispose() }
    } catch { return $null }
}

function Read-Status {
    $text = Read-Shared $statusPath
    if ($null -eq $text) { return $null }
    $status = @{ done = @() }
    foreach ($line in ($text -split "`n")) {
        $line = $line.TrimEnd("`r")
        $at = $line.IndexOf('=')
        if ($at -lt 1) { continue }
        $key = $line.Substring(0, $at)
        $value = $line.Substring($at + 1)
        if ($key -eq 'done') {
            $parts = $value -split ' '
            if ($parts.Count -ge 3) {
                $status.done += @{ name = $parts[0]; verdict = $parts[1]; seconds = [int]$parts[2] }
            }
        } else {
            $status[$key] = $value
        }
    }
    return $status
}

function Span([double]$seconds) {
    if ($seconds -lt 0) { $seconds = 0 }
    $t = [TimeSpan]::FromSeconds([math]::Floor($seconds))
    if ($t.TotalHours -ge 1) { return '{0}:{1:mm}:{1:ss}' -f [int]$t.TotalHours, $t }
    return '{0:mm}:{0:ss}' -f $t
}

function Now-Epoch { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# A suite log's progress: how many checks have said ok, and the last thing said.
function Suite-Progress([string]$log) {
    if (-not $log) { return $null }
    $path = $log
    if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $Root $log }
    $text = Read-Shared $path
    if ($null -eq $text) { return $null }
    $lines = $text -split "`n"
    $oks = @($lines | Where-Object { $_ -match '^\s+ok\s' })
    $fails = @($lines | Where-Object { $_ -match '^\s+FAIL\s' })
    $last = ''
    if ($oks.Count -gt 0) { $last = $oks[$oks.Count - 1].Trim() -replace '^ok\s+', '' }
    if ($fails.Count -gt 0) { $last = $fails[$fails.Count - 1].Trim() }
    return @{ ok = $oks.Count; fail = $fails.Count; last = $last }
}

$width = 100
try {
    $ui = $Host.UI.RawUI
    $size = $ui.WindowSize
    if ($size.Width -lt $width) {
        $buffer = $ui.BufferSize
        if ($buffer.Width -lt $width) { $buffer.Width = $width; $ui.BufferSize = $buffer }
        $size.Width = $width
        $ui.WindowSize = $size
    }
    $width = $ui.WindowSize.Width
} catch { }

# Redrawn in place rather than cleared: a clear between frames is a flicker every second.
$script:drawn = 0
$script:frame = @()
function Line([string]$text, [ConsoleColor]$color = [ConsoleColor]::Gray) {
    if ($text.Length -gt $width - 1) { $text = $text.Substring(0, $width - 4) + '...' }
    $script:frame += @{ text = $text.PadRight($width - 1); color = $color }
}

function Flush {
    try { [Console]::SetCursorPosition(0, 0) } catch { }
    foreach ($row in $script:frame) {
        Write-Host $row.text -ForegroundColor $row.color
    }
    # Whatever the last frame drew below this one is blanked.
    for ($i = $script:frame.Count; $i -lt $script:drawn; $i++) {
        Write-Host (''.PadRight($width - 1))
    }
    $script:drawn = $script:frame.Count
    $script:frame = @()
}

function Draw($status) {
    Line 'SoundGraph gate' White
    if ($null -eq $status) {
        Line ''
        Line "No gate has run on this clone yet: there is no $statusPath." Yellow
        Line 'Push something and this fills in.' Gray
        return
    }
    $now = Now-Epoch
    $started = [long]$status.run
    $ended = [long]$status.now
    $planned = @(($status.planned -split ' ') | Where-Object { $_ })
    $doneCount = $status.done.Count
    $what = ''
    if ($status.refs) { $what = "pushing $($status.refs)" }
    if ($status.remote) { $what = "$what to $($status.remote)" }
    if ($what) { Line $what.Trim() Gray }

    $state = $status.state
    switch ($state) {
        'running' {
            Line ("RUNNING   stage {0} of {1}   {2} so far" -f ($doneCount + 1), $planned.Count, (Span ($now - $started))) Yellow
        }
        'passed' {
            Line ("PASSED    all {0} stages in {1}" -f $planned.Count, (Span ($ended - $started))) Green
        }
        'refused' {
            Line ("REFUSED   after {0}" -f (Span ($ended - $started))) Red
        }
        default { Line "STATE $state" Yellow }
    }
    Line ''

    foreach ($name in $planned) {
        $finished = $status.done | Where-Object { $_.name -eq $name } | Select-Object -First 1
        if ($finished) {
            switch ($finished.verdict) {
                'ok'     { Line ("  ok    {0,-24} {1}" -f $name, (Span $finished.seconds)) Green }
                'crash'  { Line ("  ok!   {0,-24} {1}   passed, then the known teardown crash" -f $name, (Span $finished.seconds)) DarkYellow }
                'failed' { Line ("  XX    {0,-24} {1}" -f $name, (Span $finished.seconds)) Red }
                default  { Line ("  ??    {0,-24} {1}   {2}" -f $name, (Span $finished.seconds), $finished.verdict) Yellow }
            }
        } elseif ($state -eq 'running' -and $name -eq $status.stage) {
            $elapsed = Span ($now - [long]$status.stage_started)
            $progress = Suite-Progress $status.log
            if ($progress) {
                $count = "{0} checks ok" -f $progress.ok
                if ($progress.fail -gt 0) { $count = "{0}, {1} FAILED" -f $count, $progress.fail }
                Line ("  >>    {0,-24} {1}   {2}" -f $name, $elapsed, $count) Yellow
                if ($progress.last) { Line ("           {0}" -f $progress.last) DarkGray }
            } else {
                Line ("  >>    {0,-24} {1}" -f $name, $elapsed) Yellow
            }
        } else {
            Line ("  ..    {0}" -f $name) DarkGray
        }
    }

    if ($state -eq 'refused' -and $status.reason) {
        Line ''
        Line ("  {0}" -f $status.reason) Red
    }
    Line ''
    Line ("  {0}" -f (Get-Date -Format 'HH:mm:ss')) DarkGray
}

# A beep on the verdict, so a run left alone still says when it is over: two rising
# notes for a pass, one low one for a refusal.
$lastState = ''
function Announce([string]$state) {
    if ($state -eq $script:lastState) { return }
    if ($script:lastState -ne '' -and $script:lastState -ne 'running') { $script:lastState = $state; return }
    $script:lastState = $state
    try {
        if ($state -eq 'passed') { [Console]::Beep(660, 120); [Console]::Beep(880, 180) }
        elseif ($state -eq 'refused') { [Console]::Beep(220, 400) }
    } catch { }
}

try { $Host.UI.RawUI.WindowTitle = 'SoundGraph gate' } catch { }
try { [Console]::CursorVisible = $false } catch { }

while ($true) {
    $status = Read-Status
    $title = 'SoundGraph gate'
    if ($status) {
        switch ($status.state) {
            'running' { $title = "gate: $($status.stage)" }
            'passed'  { $title = 'gate: PASSED' }
            'refused' { $title = 'gate: REFUSED' }
        }
        # Only a run that was watched from its start earns a beep; a window opened on an
        # old verdict stays quiet.
        if ($lastState -eq '' -and $status.state -ne 'running') { $lastState = $status.state }
        Announce $status.state
    }
    try { $Host.UI.RawUI.WindowTitle = $title } catch { }
    Draw $status
    Flush
    if ($Once) { break }
    Start-Sleep -Milliseconds 1000
}
