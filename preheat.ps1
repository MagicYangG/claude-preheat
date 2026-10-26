#Requires -Version 5.1
<#
claude-preheat -- Claude Max 5h usage-window preheater (P1) + phase observer (P3)

Commands:
  apply          Register weekly preheat tasks from schedule.json
  status         Show window phase, scheduled preheats, recent fires
                 -Json = print one compact JSON object instead (for scripts)
  at HH:mm       One-shot: fire at the given wall-clock time (next occurrence)
  reset HH:mm    One-shot: fire so the window RESETS at the given time (fire = reset - 5h)
  +Nh / +Nm      One-shot: fire N hours/minutes from now
  fire           Fire the preheat ping immediately (used by scheduled tasks)
  learn [auto]   Derive a preheat schedule from your last 30 days of prompts
                 (median start per weekday -> suggested reset time) plus a
                 7-day window-utilization report. 'auto' writes the suggested
                 rules into schedule.json (backed up) and applies them.
                 -Json = machine-readable report (for panel.ps1)
  statusline on|off
                 Wire statusline-tap.cjs into the statusLine (pure passthrough)
                 so exact 5h/weekly reset times land in state-ratelimits.json
                 for the panel quota strip
  off            Unregister all preheat tasks

Mechanism: the Max 5h usage window is anchored by the FIRST request when no
window is active. A scheduled tiny headless ping (`claude -p "hi"`) anchors it
at a chosen time with zero model involvement beforehand. Pinging while a
window is already active is a harmless no-op (anchor unchanged).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(Position = 1)][string]$Arg,
    [switch]$Json,
    [string]$Job
)

$ErrorActionPreference = 'Stop'
# A Windows task carries no environment block, so a one-shot passes its own
# name as -Job; launchd sets CLAUDE_PREHEAT_SELF in the plist instead. The fire
# needs it to know whether it is a follow-up (Test-ChaseFire).
if ($Job -and (-not $env:CLAUDE_PREHEAT_SELF) -and ($Job -match '^ClaudePreheat-[A-Za-z0-9-]+$')) { $env:CLAUDE_PREHEAT_SELF = $Job }
$Root       = $PSScriptRoot
$ConfigPath = Join-Path $Root 'schedule.json'
$StatePath  = Join-Path $Root 'state.json'
$LogPath    = Join-Path $Root 'preheat-log.jsonl'
$FirePit    = Join-Path $Root 'firepit'
$EmptyMcp   = Join-Path $Root 'mcp-empty.json'
$FireLock   = Join-Path $Root '.fire.lock'
$TaskWkPrefix   = 'ClaudePreheat-Wk'
$TaskOncePrefix = 'ClaudePreheat-Once'
$WindowHours = 5

$DayMap   = @{ Mon = 'Monday'; Tue = 'Tuesday'; Wed = 'Wednesday'; Thu = 'Thursday'; Fri = 'Friday'; Sat = 'Saturday'; Sun = 'Sunday' }
$DayOrder = @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')

# OS adapter: scheduling backends (Task Scheduler / launchd), wake warnings,
# toasts, home-dir resolution. Shared with panel.ps1.
. (Join-Path $Root 'platform.ps1')

function Read-Config {
    if (-not (Test-Path $ConfigPath)) { throw "schedule.json not found at $ConfigPath" }
    Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Read-State {
    if (Test-Path $StatePath) {
        try { Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
    } else { $null }
}

function Write-State($obj) { $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $StatePath -Encoding UTF8 }

function Write-Log($obj) {
    # InvariantCulture: the chase gate parses this stamp back (ConvertTo-LocalTime).
    # A Buddhist/Hijri calendar or a non-':' time separator would round-trip to
    # nothing and the gate would fail open.
    $obj.ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture)
    # rotation + append under one named mutex: overlapping fires (or a fire and
    # the panel) could otherwise read 1000 lines, then each write their own
    # truncated copy, losing the other's entries. Logging stays lossy telemetry
    # though - nothing in here may throw, mutex or not.
    $m = $null
    try { $m = New-Object System.Threading.Mutex($false, 'claude-preheat-journal') } catch { }
    $held = $false
    try {
        if ($m) {
            try { $held = $m.WaitOne(2000) }
            catch [System.Threading.AbandonedMutexException] { $held = $true }
            catch { $held = $false }
        }
        try {
            if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 2MB)) {
                $keep = Get-Content $LogPath -Tail 1000 -Encoding UTF8
                Set-Content -Path $LogPath -Value $keep -Encoding UTF8
            }
        } catch { }
        ($obj | ConvertTo-Json -Compress -Depth 5) | Add-Content -Path $LogPath -Encoding UTF8
    } catch { } finally {
        if ($m) {
            if ($held) { try { $m.ReleaseMutex() } catch { } }
            try { $m.Dispose() } catch { }
        }
    }
}

function Get-FireEvents([string]$path, [int]$max = 60) {
    # the journal's fire records, newest first, trimmed to what a reader shows
    # (the panel's fire-history list). Pure in $path so a synthetic journal
    # exercises every record shape without spending a token. Never throws:
    # a half-rotated or hand-edited journal just yields fewer records.
    $out = New-Object System.Collections.Generic.List[object]
    if ($path -and (Test-Path $path)) {
        $lines = @()
        try { $lines = @(Get-Content $path -Tail 400 -Encoding UTF8) } catch { $lines = @() }
        $pendingChase = $null
        for ($i = $lines.Count - 1; ($i -ge 0) -and ($out.Count -lt $max); $i--) {
            $e = $null
            try { $e = $lines[$i] | ConvertFrom-Json } catch { continue }
            if ((-not $e) -or ($e.ev -ne 'fire')) {
                # a chase booking is written right after the fire that booked it
                # (so it is the NEWER line): remember it for that fire's record
                if ($e -and ($e.ev -eq 'schedule-once') -and $e.PSObject.Properties['label'] -and ([string]$e.label -like 'chase*')) {
                    $pendingChase = @{ ts = (ConvertTo-LocalTime $e.ts); at = (ConvertTo-LocalTime $e.fireAt) }
                }
                continue
            }
            # pwsh 7 turns an ISO string into a DateTime on parse and [string] would
            # then hand back the desktop culture's format - keep the journal's own text
            $ts = [string]$e.ts
            if ($lines[$i] -match '"ts"\s*:\s*"([^"]+)"') { $ts = $Matches[1] }
            $rec = [ordered]@{ ts = $ts; ok = [bool]$e.ok; anchored = $null; kind = $null; attempts = $null; last_local_activity = $null; err = $null; chase_at = $null; resets_at = $null }
            if ($pendingChase) {
                $fts = ConvertTo-LocalTime $e.ts
                if ($fts -and $pendingChase.ts -and $pendingChase.at -and ($pendingChase.ts -ge $fts) -and (($pendingChase.ts - $fts).TotalMinutes -le 5)) {
                    $rec.chase_at = $pendingChase.at.ToString('yyyy-MM-dd HH:mm')
                }
                $pendingChase = $null
            }
            if ($e.PSObject.Properties['anchored'] -and ($null -ne $e.anchored)) { $rec.anchored = [bool]$e.anchored }
            if ($e.PSObject.Properties['kind'] -and $e.kind) { $rec.kind = [string]$e.kind }
            if ($e.PSObject.Properties['attempts'] -and ($null -ne $e.attempts)) { $rec.attempts = [int]$e.attempts }
            if ($e.PSObject.Properties['last_local_activity'] -and $e.last_local_activity) { $rec.last_local_activity = [string]$e.last_local_activity }
            if ($e.PSObject.Properties['resets_at'] -and $e.resets_at) { $rec.resets_at = [string]$e.resets_at }
            if ($e.PSObject.Properties['err'] -and $e.err) {
                $s = [string]$e.err
                $rec.err = $s.Substring(0, [Math]::Min(120, $s.Length))
            }
            [void]$out.Add($rec)
        }
    }
    # plain output (callers wrap in @()): a `,`-wrapped return survives a bare
    # assignment but @(...) at the call site then nests the whole list as one item
    $out.ToArray()
}

function Resolve-ClaudeExe {
    param([switch]$NoCache)
    if (-not $NoCache) {
        $state = Read-State
        if ($state -and $state.claude -and (Test-Path $state.claude)) { return $state.claude }
    }
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd) {
        $src = $cmd.Source
        if ($src -like '*.ps1') {
            # npm shim: prefer the .cmd sibling so Start-Process can launch it directly
            $sib = [System.IO.Path]::ChangeExtension($src, '.cmd')
            if (Test-Path $sib) { return $sib }
        }
        return $src
    }
    $cands = if ($OnMac) {
        @((Join-Path $HOME '.local/bin/claude'), '/opt/homebrew/bin/claude', '/usr/local/bin/claude')
    } else {
        @("$env:APPDATA\npm\claude.cmd", "$env:USERPROFILE\.local\bin\claude.exe")
    }
    foreach ($cand in $cands) {
        if (Test-Path $cand) { return $cand }
    }
    throw 'claude CLI not found (PATH incomplete in this context and no known fallback matched)'
}

function Get-Proxy {
    # empty/missing config proxy -> $null (callers must skip setting HTTPS_PROXY/HTTP_PROXY)
    if (Test-Path $ConfigPath) {
        try {
            $c = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($c.proxy) { return $c.proxy }
        } catch { }
    }
    $null
}

function Get-FireSpecs($config) {
    # rule { days:[Mon..]; reset:'HH:mm' } -> @{ Days = full names (shifted if fire crosses midnight); FireTime = timespan; Reset }
    $specs = @()
    foreach ($rule in $config.rules) {
        # InvariantCulture, not $null: $null means CurrentCulture, whose calendar
        # (th-TH, ar-SA) and time separator can reject or misread a plain HH:mm
        $reset = [datetime]::ParseExact($rule.reset, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        $fire  = $reset.TimeOfDay - [timespan]::FromHours($WindowHours)
        $shift = 0
        if ($fire -lt [timespan]::Zero) { $fire = $fire + [timespan]::FromDays(1); $shift = -1 }
        $days = @()
        foreach ($d in $rule.days) {
            $full = $DayMap[$d]
            if (-not $full) { throw "Unknown day '$d' in schedule.json (use Mon..Sun)" }
            if ($shift -eq 0) { $days += $full }
            else {
                $i = $DayOrder.IndexOf($full)
                $days += $DayOrder[(($i + 7 + $shift) % 7)]
            }
        }
        $specs += @{ Days = $days; FireTime = $fire; Reset = $rule.reset }
    }
    $specs
}

function Invoke-Apply {
    Wait-FireLock
    $config = Read-Config
    # @(): a single-rule schedule.json unrolls to a bare hashtable, whose .Count
    # is the hashtable's key count, not 1
    $specs  = @(Get-FireSpecs $config)
    # resolve claude path now, in an interactive shell where PATH is complete
    Write-State @{ claude = (Resolve-ClaudeExe); pwsh = (Resolve-HostShell); appliedAt = (Get-Date).ToString('s') }
    # compute every task BEFORE deleting the old ones: a spec that throws here
    # used to leave the machine with no weekly tasks at all and no way to know
    $plan = @()
    foreach ($s in $specs) {
        # StartBoundary must be in the future, else the scheduler's week alignment
        # can skip the nearest occurrence (observed: Sat task jumping a full week)
        $at = (Get-Date).Date + $s.FireTime
        if ($at -le (Get-Date)) { $at = $at.AddDays(1) }
        $dayTag = ($s.Days | ForEach-Object { $_.Substring(0, 3) }) -join ''
        $plan += @{
            Name     = '{0}-{1}-{2}' -f $TaskWkPrefix, $s.FireTime.ToString('hhmm'), $dayTag
            Days     = $s.Days
            At       = $at
            FireTime = $s.FireTime
            Reset    = $s.Reset
        }
    }
    Remove-PreheatJobs "$TaskWkPrefix*"
    try { Remove-StaleOnceJobs } catch { }
    if ($OnMac) { Limit-LaunchdErrLog }
    $failed = @()
    foreach ($job in $plan) {
        try {
            Register-PreheatJob -Name $job.Name -Days $job.Days -At $job.At
            Write-Host ('registered  {0}  fire {1}  -> reset {2}  [{3}]' -f $job.Name, $job.FireTime.ToString('hh\:mm'), $job.Reset, ($job.Days -join ','))
        } catch {
            # one rejected task must not abandon the rest half-applied
            $failed += ('{0}: {1}' -f $job.Name, $_.Exception.Message)
            Write-Host ('FAILED      {0}  {1}' -f $job.Name, $_.Exception.Message) -ForegroundColor Red
        }
    }
    if ($failed.Count -gt 0) {
        Write-Log @{ ev = 'apply'; tasks = $plan.Count; failed = $failed.Count }
        throw ('apply registered {0} of {1} tasks - failed: {2}' -f ($plan.Count - $failed.Count), $plan.Count, ($failed -join '; '))
    }
    Write-Log @{ ev = 'apply'; tasks = $plan.Count }
    Test-WakeTimers
}

function Wait-FireLock([int]$MaxSec = 90) {
    # apply/off rewrite or delete the very job a running fire lives inside - on
    # macOS bootout SIGTERMs that fire mid-ping, on Windows the re-register
    # races it. Wait the fire out instead of racing it.
    if (-not (Test-Path $FireLock)) { return }
    try {
        # a fire cannot outlive 3 x 240s + 2 x 90s, so anything older is a
        # leftover from a killed process, not a live ping
        if ((Get-Item $FireLock).LastWriteTime -lt (Get-Date).AddMinutes(-20)) {
            Remove-Item $FireLock -Force -ErrorAction SilentlyContinue
            return
        }
    } catch { return }
    $waited = 0
    while ((Test-Path $FireLock) -and ($waited -lt $MaxSec)) {
        Start-Sleep -Seconds 3
        $waited += 3
    }
    if (Test-Path $FireLock) {
        $job = '?'; $started = '?'
        try {
            $l = Get-Content $FireLock -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
            if ($l) {
                if ($l.job) { $job = [string]$l.job }
                # ConvertFrom-Json may hand the ISO string back as a [datetime];
                # format it ourselves or the message follows the current culture
                if ($l.startedAt) { $started = ([datetime]$l.startedAt).ToString('s') }
            }
        } catch { }
        throw ('a preheat fire is running right now (job {0}, started {1}) - try again in a minute' -f $job, $started)
    }
}

function Get-TranscriptActivity($file) {
    # Newest REAL turn in a transcript, as local time. Two traps this avoids,
    # both observed live:
    #  1. file mtime lies - local tools (indexers, backups) bump it without
    #     appending a single byte, so a dead session looks active "just now"
    #  2. not every record is an API turn - Claude Code appends attachment /
    #     away_summary / turn_duration / stop_hook_summary bookkeeping to an
    #     OPEN-BUT-IDLE session, so "the file grew" does not mean the model
    #     was called and does not mean a usage window was anchored
    # Only user/assistant records count as a turn.
    try {
        $fs = [System.IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
        try {
            $take = [int][Math]::Min(2097152, $fs.Length)
            $null = $fs.Seek(-$take, [System.IO.SeekOrigin]::End)
            $buf  = New-Object byte[] $take
            $read = $fs.Read($buf, 0, $take)
            $txt  = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Close() }
        $best = $null
        foreach ($line in ($txt -split "`n")) {
            if ($line -notmatch '"type"\s*:\s*"(assistant|user)"') { continue }
            if ($line -notmatch '"timestamp"\s*:\s*"([^"]+)"') { continue }
            $v = $Matches[1]
            if ((-not $best) -or ($v -gt $best)) { $best = $v }   # ISO-8601 UTC sorts lexically
        }
        if ($best) { return ([datetimeoffset]::Parse($best)).LocalDateTime }
    } catch { }
    $null
}

function Get-LastLocalActivity {
    # last locally visible Claude usage, judged by transcript CONTENT.
    # Blind to phone/web usage - like any local observation.
    try {
        $proj = Join-Path (Join-Path (Get-ClaudeHome) '.claude') 'projects'
        if (-not (Test-Path $proj)) { return $null }
        # 20 newest by mtime, not 8: a day of parallel sessions plus background
        # agents easily writes more than 8 transcripts, and the one carrying the
        # newest real turn can sit below the cut
        $files = @(Get-ChildItem -Path $proj -Filter '*.jsonl' -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 20)
        $best = $null
        foreach ($f in $files) {
            $t = Get-TranscriptActivity $f.FullName
            if (-not $t) { continue }
            if ((-not $best) -or ($t -gt $best)) { $best = $t }
        }
        return $best
    } catch { return $null }
}

function Get-KnownWindowEnd([string]$path = $null) {
    # the exact end of the 5h window last seen. Transcript activity only says
    # WHEN the account was busy; state-ratelimits.json says when that window
    # expires - written on every statusline render (CLI only: the desktop app
    # runs Claude Code headless, no statusline) and by every fire from its own
    # ping's rate_limit_event (Write-RateLimitCache).
    # $null when the tap is not installed or the file is unreadable.
    try {
        if (-not $path) { $path = Join-Path $Root 'state-ratelimits.json' }
        if (-not (Test-Path $path)) { return $null }
        $o = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $r = $o.rate_limits.five_hour.resets_at
        if (-not $r) { return $null }
        return [DateTimeOffset]::FromUnixTimeSeconds([long]$r).LocalDateTime
    } catch { return $null }
}

function Split-PingStream([string]$StdOut) {
    # `claude -p --output-format stream-json --verbose` prints one JSON event a
    # line: hook chatter, init, the reply, a rate_limit_event and, last, the
    # very object `--output-format json` used to print alone. The verdict
    # (Test-PingOutput) reads that result line; the rate_limit_event says when
    # the 5h window really ends. Pure.
    # -> @{ result = <the result line> | <the text itself when it is no stream>
    #               | '' (a stream that never got to its result);
    #       rl = <rate_limit_info> | $null }
    $res = @{ result = ''; rl = $null }
    if (-not $StdOut) { return $res }
    $isStream = $false; $resultLine = $null
    $loose = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($StdOut -split '\r?\n')) {
        $s = $line.Trim()
        if (-not $s) { continue }
        $e = $null; $type = $null
        if ($s.StartsWith('{')) {
            try { $e = $s | ConvertFrom-Json } catch { $e = $null }
            if ($e -and $e.PSObject.Properties['type']) { $type = [string]$e.type }
            # a line that no longer parses still names its type up front
            elseif ($s -match '^\{\s*"type"\s*:\s*"([A-Za-z_]+)"') { $type = $Matches[1] }
        }
        if (-not $type) { [void]$loose.Add($s); continue }   # plain text: the CLI's own output
        $isStream = $true
        switch ($type) {
            'result' { $resultLine = $s; break }
            'rate_limit_event' { if ($e -and $e.PSObject.Properties['rate_limit_info'] -and $e.rate_limit_info) { $res.rl = $e.rate_limit_info }; break }
            # hook chatter carries whatever the user's own hooks printed, the
            # reply is the model's: neither belongs in a log line
            { $_ -in @('system', 'assistant', 'user', 'stream_event') } { break }
            default { [void]$loose.Add($s) }
        }
    }
    if ($resultLine) { $res.result = $resultLine }
    elseif (-not $isStream) { $res.result = $StdOut }
    # a stream cut short: hand the verdict what the CLI itself said (an auth
    # error must still read as auth - no retries, the login toast), or ''
    elseif ($loose.Count) { $res.result = ($loose -join "`n") }
    $res
}

function ConvertFrom-RateLimitInfo($rl) {
    # rate_limit_info -> the statusline tap's shape (five_hour / seven_day, each
    # used_percentage + resets_at in epoch seconds), so the panel and
    # Get-KnownWindowEnd read one format whoever wrote the cache. $null when
    # it says nothing about the 5h window: writing that would only erase what
    # the tap knew. Utilization arrives as a fraction (0.32 - past 1.0 with
    # overage); used_percentage is percent, like the tap's.
    if (-not $rl) { return $null }
    $toWin = {
        param($o)
        if ((-not $o) -or (-not $o.PSObject.Properties['resetsAt']) -or (-not $o.resetsAt)) { return $null }
        $w = [ordered]@{ used_percentage = $null; resets_at = [long]$o.resetsAt }
        if ($o.PSObject.Properties['utilization'] -and ($null -ne $o.utilization)) {
            # a value that is no number leaves the percent unknown - the reset still counts
            try { $w.used_percentage = [int][Math]::Round(([double]$o.utilization) * 100) } catch { }
        }
        $w
    }
    $five = $null; $week = $null
    if ($rl.PSObject.Properties['unifiedWindows'] -and $rl.unifiedWindows) {
        $uw = $rl.unifiedWindows
        if ($uw.PSObject.Properties['five_hour']) { $five = & $toWin $uw.five_hour }
        if ($uw.PSObject.Properties['seven_day']) { $week = & $toWin $uw.seven_day }
    }
    # older payloads: only the binding limit, at the top level
    if ((-not $five) -and $rl.PSObject.Properties['rateLimitType'] -and ($rl.rateLimitType -eq 'five_hour')) { $five = & $toWin $rl }
    if (-not $five) { return $null }
    $out = [ordered]@{ five_hour = $five }
    if ($week) { $out.seven_day = $week }
    $out
}

function Write-RateLimitCache($windows, [string]$path = $null, [string]$source = 'fire') {
    # the file the statusline tap writes (state-ratelimits.json): with only the
    # desktop app in use nothing else ever refreshes it, and both the panel's
    # quota strip and the chase read it. temp + replace: no reader ever sees
    # half a file. A reader holding it open at that very instant (no
    # FILE_SHARE_DELETE) makes the replace fail: one retry, then this reading
    # waits for the next fire. Telemetry: never throws.
    if (-not $windows) { return }
    if (-not $path) { $path = Join-Path $Root 'state-ratelimits.json' }
    $tmp = $path + '.tmp-' + $PID
    try {
        $obj = [ordered]@{
            capturedAt  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
            source      = $source
            rate_limits = $windows
        }
        # not $json: the script's own [switch]$Json param is the same variable to
        # PowerShell, and a string assigned to it throws
        $text = ConvertTo-Json -InputObject $obj -Compress -Depth 6
        [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
        for ($n = 1; $n -le 2; $n++) {
            try {
                # [NullString]: a bare $null reaches a .NET string parameter as '' ("the path is empty")
                if (Test-Path $path) { [System.IO.File]::Replace($tmp, $path, [NullString]::Value) }
                else { [System.IO.File]::Move($tmp, $path) }
                break
            } catch {
                if ($n -ge 2) { throw }
                Start-Sleep -Milliseconds 50
            }
        }
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Read-PingFile([string]$path) {
    # the ping's redirected stdout/stderr: UTF-8 without a BOM. Windows
    # PowerShell 5.1 reads such a file in the ANSI code page (936 on a Chinese
    # desktop), where a GBK lead byte swallows the quote after a Chinese reply:
    # the result line stopped parsing and a good ping was judged a failure.
    if (-not (Test-Path $path)) { return '' }
    $t = Get-Content $path -Raw -Encoding UTF8
    if ($null -eq $t) { return '' }
    $t
}

function Test-AnchorFromWindow([datetime]$FireStart, $WindowEnd) {
    # ground truth for "did this ping open a NEW window?": its own
    # rate_limit_event says when the 5h window ends right after it. Ending ~5h
    # out = this ping opened it; sooner = one was already running. The end is
    # truncated (a 04:10:13 ping -> 09:10, 18:01:07 -> 23:00), hence the
    # 15-minute margin - which also counts a window someone opened under 15
    # minutes before the fire as ours: harmless, it ends within 15 minutes of
    # the reset the schedule asked for.
    # -> $true | $false | $null (no usable end: fall back to the activity guess)
    if (-not $WindowEnd) { return $null }
    $left = ($WindowEnd.ToUniversalTime() - $FireStart.ToUniversalTime()).TotalMinutes
    if ($left -le 0) { return $null }
    $left -ge ($WindowHours * 60 - 15)
}

function Test-FreshAnchor([datetime]$FireStart, $LastAct, $KnownEnd, $LastPreheatAnchor = $null) {
    # did this ping open a NEW window? No when a preheat ping of our own opened
    # one inside the last 5h: the ping runs in firepit/ and leaves no transcript,
    # so only the journal knows - and a chase-opened window is exactly where the
    # next weekly fire lands. Otherwise yes when nothing local ran in the 5h
    # before it, or when the tap saw the running window END before the fire and
    # nobody used the account after that end (a later turn would have opened a
    # window whose end we do not know). Blind to phone/web use, like every
    # local observation. UTC arithmetic: a local-time gap that straddles a DST
    # switch is off by an hour.
    if ($LastPreheatAnchor -and (($FireStart.ToUniversalTime() - $LastPreheatAnchor.ToUniversalTime()).TotalHours -lt $WindowHours)) { return $false }
    if (-not $LastAct) { return $true }
    if (($FireStart.ToUniversalTime() - $LastAct.ToUniversalTime()).TotalHours -ge $WindowHours) { return $true }
    if ($KnownEnd -and ($KnownEnd -le $FireStart) -and ($LastAct -le $KnownEnd)) { return $true }
    $false
}

function ConvertTo-LocalTime($v) {
    # journal timestamps: a string on 5.1, already a DateTime on pwsh 7
    if ($null -eq $v) { return $null }
    if ($v -is [datetime]) { return $v }
    if ($v -is [datetimeoffset]) { return $v.LocalDateTime }
    try { return ([datetimeoffset]::Parse([string]$v, [System.Globalization.CultureInfo]::InvariantCulture)).LocalDateTime } catch { return $null }
}

function Get-JournalEvents([string]$path, [int]$max = 200) {
    # every journal record, newest first; bad lines skipped; ts as local
    # DateTime (or $null). Never throws.
    $out = New-Object System.Collections.Generic.List[object]
    if ($path -and (Test-Path $path)) {
        $lines = @()
        try { $lines = @(Get-Content $path -Tail 400 -Encoding UTF8) } catch { $lines = @() }
        for ($i = $lines.Count - 1; ($i -ge 0) -and ($out.Count -lt $max); $i--) {
            $e = $null
            try { $e = $lines[$i] | ConvertFrom-Json } catch { continue }
            if (-not $e) { continue }
            $t = $null
            if ($e.PSObject.Properties['ts']) { $t = ConvertTo-LocalTime $e.ts }
            [void]$out.Add(@{ ev = [string]$e.ev; ts = $t; rec = $e })
        }
    }
    $out.ToArray()
}

function Get-LastPreheatAnchor([string]$path = $null) {
    # when did a preheat ping of our own last open a window? (newest journal
    # fire with ok + anchored). $null when none in the journal tail.
    if (-not $path) { $path = $LogPath }
    foreach ($j in @(Get-JournalEvents $path 200)) {
        $e = $j.rec
        if (($j.ev -eq 'fire') -and $j.ts -and $e.ok -and $e.PSObject.Properties['anchored'] -and ($e.anchored -eq $true)) { return $j.ts }
    }
    $null
}

function Test-RecentPreheatAnchor([datetime]$Before, [string]$path = $null) {
    # true when a preheat ping opened the window that is running now (an
    # anchored fire inside the last 5h), or a chase for this very gap is
    # already on the books. This is what stops chase chains: a chase anchors
    # a window, the next weekly fire lands inside it, and that fire must NOT
    # chase again - or the tool would re-anchor every 5h forever.
    if (-not $path) { $path = $LogPath }
    $from = $Before.AddHours(-$WindowHours)
    foreach ($j in @(Get-JournalEvents $path 200)) {
        $e = $j.rec
        if ($j.ev -eq 'fire') {
            if ($j.ts -and ($j.ts -gt $from) -and ($j.ts -le $Before) -and $e.ok -and
                $e.PSObject.Properties['anchored'] -and ($e.anchored -eq $true)) { return $true }
        } elseif ($j.ev -eq 'schedule-once') {
            $lbl = ''
            if ($e.PSObject.Properties['label']) { $lbl = [string]$e.label }
            if ($lbl -like 'chase*') {
                $at = $null
                if ($e.PSObject.Properties['fireAt']) { $at = ConvertTo-LocalTime $e.fireAt }
                # only a chase still PENDING counts; one that came due is judged by
                # the fire record it produced (a missed one-shot is never replayed,
                # so it must not block the next fire's chase for 5h)
                if ($at -and ($at -gt $Before) -and ($at -le $Before.AddHours($WindowHours).AddMinutes(5))) { return $true }
            }
        }
    }
    $false
}

function Test-ChaseFire([string]$Self, [string]$path = $null) {
    # is this fire itself a follow-up? Its job name ($env:CLAUDE_PREHEAT_SELF)
    # is the one-shot Invoke-Once derived from fireAt, and the journal's
    # 'schedule-once' record with a chase label carries that fireAt. Matching
    # the name, not a time window, also recognises a follow-up launchd ran
    # late after a sleep. -> $true / $false
    if ((-not $Self) -or ($Self -notlike ($TaskOncePrefix + '-*'))) { return $false }
    if (-not $path) { $path = $LogPath }
    foreach ($j in @(Get-JournalEvents $path 200)) {
        $e = $j.rec
        if (($j.ev -ne 'schedule-once') -or (-not $e.PSObject.Properties['label']) -or ([string]$e.label -notlike 'chase*')) { continue }
        $at = $null
        if ($e.PSObject.Properties['fireAt']) { $at = ConvertTo-LocalTime $e.fireAt }
        if ($at -and (($TaskOncePrefix + '-' + $at.ToString('yyyyMMdd-HHmm', [System.Globalization.CultureInfo]::InvariantCulture)) -eq $Self)) { return $true }
    }
    $false
}

function Get-NextWeeklyFire([datetime]$After) {
    # the next weekly fire time after $After, from schedule.json (not from the
    # scheduler: the answer must not depend on which backend is registered).
    # $null when there is no usable schedule.
    $best = $null
    try {
        foreach ($s in @(Get-FireSpecs (Read-Config))) {
            foreach ($d in $s.Days) {
                $cand = $After.Date + $s.FireTime
                $guard = 0
                while ((($cand.DayOfWeek.ToString() -ne $d) -or ($cand -le $After)) -and ($guard -lt 9)) { $cand = $cand.AddDays(1); $guard++ }
                if ((-not $best) -or ($cand -lt $best)) { $best = $cand }
            }
        }
    } catch { return $null }
    $best
}

function Get-ChasePlan {
    # A scheduled ping that lands in a running window did not do its job: the
    # schedule wanted a fresh window anchored at fire time, so that the reset
    # lands 5h later - inside the user's session. Chase = ping again one
    # minute after the running window expires, the earliest moment the
    # intended anchor can still happen - unless the next weekly fire comes
    # before the chase's OWN window would end: that fire would land inside it,
    # miss its reset, and (no chains) not chase either. Pure: every input is a
    # parameter so the self-test can walk the edges without a clock or a scheduler.
    # -> @{ at; source; end }  or  @{ skip = reason }
    param([datetime]$FireStart, $LastAct, $KnownEnd, $NextWeekly, [bool]$RecentAnchor, [datetime]$Now, [bool]$IsChase = $false)
    # once per gap: a follow-up that rides a window again does not book another
    # (with the account kept busy, chase after chase only rode window after window)
    if ($IsChase) { return @{ skip = 'a follow-up does not chase again (once per gap)' } }
    if ($RecentAnchor) { return @{ skip = 'a preheat anchored the running window (no chase chains)' } }
    # exact when the tap or this fire's own rate_limit_event saw the running
    # window (its end still ahead of the fire) - then nothing local is needed:
    # a window opened from a phone or claude.ai ends just the same
    $known = [bool]($KnownEnd -and ($KnownEnd -gt $FireStart))
    if ((-not $LastAct) -and (-not $known)) { return @{ skip = 'no local activity to chase' } }
    $end = $null; $src = $null
    # upper bound: the running window opened no later than the last local
    # turn, so it ends no later than 5h after it
    if ($LastAct) { $end = $LastAct.ToUniversalTime().AddHours($WindowHours).ToLocalTime(); $src = 'estimate' }
    if ($known) { $end = $KnownEnd; $src = 'ratelimits' }
    # two whole minutes, not 60s: resets_at is truncated to the minute, so a
    # +60s chase could still land a second inside the old window
    $at = $end.AddMinutes(2)
    if ($at -lt $Now.AddMinutes(2)) { $at = $Now.AddMinutes(2) }
    if ($NextWeekly -and ($NextWeekly -lt $at.AddHours($WindowHours))) {
        return @{ skip = ('next scheduled preheat ' + $NextWeekly.ToString('MM-dd HH:mm') + ' comes first') }
    }
    @{ at = $at; source = $src; end = $end }
}

function Invoke-Chase([datetime]$FireStart, $LastAct, $KnownEnd) {
    # "chase": false in schedule.json turns follow-ups off (default on)
    $cfg = $null
    try { $cfg = Read-Config } catch { }
    if ($cfg -and $cfg.PSObject.Properties['chase'] -and ($cfg.chase -eq $false)) {
        Write-Log @{ ev = 'chase-skip'; reason = 'chase disabled in schedule.json' }
        return @{ skip = 'disabled' }
    }
    $now  = Get-Date
    $plan = Get-ChasePlan -FireStart $FireStart -LastAct $LastAct -KnownEnd $KnownEnd `
        -NextWeekly (Get-NextWeeklyFire $now) -RecentAnchor (Test-RecentPreheatAnchor $FireStart) -Now $now `
        -IsChase (Test-ChaseFire $env:CLAUDE_PREHEAT_SELF)
    if ($plan.skip) { Write-Log @{ ev = 'chase-skip'; reason = $plan.skip }; return $plan }
    # -NoWake: a follow-up is best effort - it must never wake a sleeping PC at
    # a minute the user did not choose (the weekly fires keep their wake timers)
    Invoke-Once $plan.at ('chase ' + $plan.source) -NoWake
    $plan
}

function Test-SpentOnce($job, [datetime]$Now) {
    # a one-shot whose time has passed: on Windows its trigger is spent, on
    # macOS the name still decodes to that past time until the next fire or
    # apply sweeps it (Remove-StaleOnceJobs) - say so instead of listing a
    # "next" run that is behind us
    # Windows reports NO next run for a spent one-time trigger; macOS decodes
    # the past time from the name - both mean spent
    ($job.name -like ($TaskOncePrefix + '-*')) -and ((-not $job.next) -or ($job.next -lt $Now.AddMinutes(-3)))
}

function Test-PingOutput([int]$ExitCode, [string]$StdOut, [string]$StdErr) {
    # PURE, so one ping's verdict is testable without spending a token.
    # `claude -p --output-format json` can exit 0 and still report the failure
    # INSIDE the payload (is_error) - judging by exit code alone logged an
    # expired login as a successful preheat, day after day.
    # -> @{ ok; cost; err; kind = 'auth' | 'other' | $null }
    $res = @{ ok = $false; cost = $null; err = $null; kind = $null }
    # parse the payload FIRST, whatever the exit code: a usage-limit hit exits 1
    # with the reason in `result` and nothing on stderr - and the head of that
    # JSON is 400 bytes of zeroed usage counters, which is all the log kept of
    # the one real failure it ever saw
    $j = $null
    if ($StdOut) { try { $j = $StdOut | ConvertFrom-Json } catch { } }
    $payloadErr = $null
    if ($j -and $j.PSObject.Properties['is_error'] -and $j.is_error) {
        if ($j.PSObject.Properties['result'] -and $j.result) { $payloadErr = ([string]$j.result -split "`n")[0] }
        if (-not $payloadErr) { $payloadErr = 'claude reported is_error' }
    }
    if (($ExitCode -ne 0) -or (-not $StdOut)) {
        $e = $payloadErr
        if (-not $e) { $e = $StdErr }
        if (-not $e) { $e = 'exit={0} {1}' -f $ExitCode, $StdOut.Substring(0, [Math]::Min(400, $StdOut.Length)) }
        $res.err = $e
    } elseif ($payloadErr) {
        $res.err = $payloadErr
    } else {
        $res.ok = $true
        if ($j -and $j.PSObject.Properties['total_cost_usd']) { $res.cost = $j.total_cost_usd }
    }
    if (-not $res.ok) {
        $res.err = $res.err.Substring(0, [Math]::Min(400, $res.err.Length))
        # an expired login is the one failure the user can fix in ten seconds -
        # worth telling them apart from a network blip; a usage limit is the one
        # nothing fixes until the window resets, so it must not be retried
        if ($res.err -match '(?i)not logged in|log ?in|authenticat|unauthori[sz]ed|expired|invalid api key|oauth') { $res.kind = 'auth' }
        elseif ($res.err -match '(?i)usage limit|session limit|rate.?limit|limit reached|hit your limit') { $res.kind = 'limit' }
        else { $res.kind = 'other' }
    }
    $res
}

function Invoke-Fire {
    # nothing before the ping may block the ping
    try { Remove-StaleOnceJobs } catch { }
    # claim this moment so apply/off wait instead of unregistering the job we
    # are running inside. Best effort in both directions: a lock we cannot
    # write, and a lock we cannot delete, must never cost the ping.
    $ownLock = $false
    try {
        # a fresh lock held by another LIVE fire is theirs: leave it, and let
        # the finally below skip the delete - a manual fire that finishes in
        # 8s must not unlock a scheduled fire still on its retries
        $other = $null
        if (Test-Path $FireLock) {
            try {
                $prev = Get-Content $FireLock -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                if ($prev -and $prev.pid -and ((Get-Item $FireLock).LastWriteTime -gt (Get-Date).AddMinutes(-20)) -and
                    (Get-Process -Id ([int]$prev.pid) -ErrorAction SilentlyContinue)) { $other = $prev }
            } catch { }
        }
        if (-not $other) {
            @{ pid = $PID; job = $env:CLAUDE_PREHEAT_SELF; startedAt = (Get-Date).ToString('s') } |
                ConvertTo-Json -Compress | Set-Content -Path $FireLock -Encoding UTF8
            $ownLock = $true
        }
    } catch { }
    try {
        $proxy = Get-Proxy
        if ($proxy) { $env:HTTPS_PROXY = $proxy; $env:HTTP_PROXY = $proxy }
        if (-not (Test-Path $FirePit)) {
            # -Force + SilentlyContinue: two near-simultaneous fires must not die on check-then-create
            New-Item -ItemType Directory -Path $FirePit -Force -ErrorAction SilentlyContinue | Out-Null
        }

        $claude = $null
        try { $claude = Resolve-ClaudeExe } catch {
            Write-Log @{ ev = 'fire'; ok = $false; err = 'claude CLI not found'; kind = 'other' }
            Send-Toast $false $null 'other'
            return
        }

        # local-activity snapshot BEFORE the ping (metadata read only): if no
        # transcript changed in the 5h before fire time, no locally visible
        # window was active, so a successful ping anchored a fresh one
        $fireStart = Get-Date
        $lastAct   = Get-LastLocalActivity
        $knownEnd  = Get-KnownWindowEnd
        $ownAnchor = Get-LastPreheatAnchor

        $pingArgs = '-p "hi" --model haiku --no-session-persistence --strict-mcp-config --mcp-config "{0}" --output-format stream-json --verbose' -f $EmptyMcp
        $ok = $false; $attempts = 0; $cost = $null; $ms = $null; $errText = $null; $kind = $null; $rlInfo = $null; $rlOk = $null

        while (-not $ok -and $attempts -lt 3) {
            $attempts++
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            # unique per invocation+attempt: overlapping fires must not share redirect files
            $outFile = Join-Path $Root ('.fire-out-{0}-{1}.tmp' -f $PID, $attempts)
            $errFile = Join-Path $Root ('.fire-err-{0}-{1}.tmp' -f $PID, $attempts)
            try {
                $p = Start-Process -FilePath $claude -ArgumentList $pingArgs -WorkingDirectory $FirePit `
                    -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -NoNewWindow
                $null = $p.Handle   # PS 5.1: without touching Handle first, ExitCode reads null forever
                if (-not $p.WaitForExit(240000)) {
                    try { $p.Kill() } catch { }
                    throw 'timeout after 240s'
                }
                $sw.Stop(); $ms = $sw.ElapsedMilliseconds
                $stdout = ''
                $stdout = Read-PingFile $outFile
                $stderrText = ''
                $stderrText = Read-PingFile $errFile
                # stream-json: the verdict reads the result line, the rate_limit_event rides along
                $split = Split-PingStream $stdout
                if ($split.rl) { $rlInfo = $split.rl }
                $verdict = Test-PingOutput $p.ExitCode $split.result $stderrText
                if ($verdict.ok) { $ok = $true; $cost = $verdict.cost; $rlOk = $split.rl }
                else { $errText = $verdict.err; $kind = $verdict.kind }
            } catch {
                $sw.Stop()
                $v = Test-PingOutput 1 '' $_.Exception.Message
                $errText = $v.err; $kind = $v.kind
            } finally {
                Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
            }
            # neither an expired login nor a usage limit heals in 90s: two more
            # attempts only spend three minutes and log the same line thrice
            if (-not $ok -and ($kind -eq 'auth' -or $kind -eq 'limit')) { break }
            if (-not $ok -and $attempts -eq 1) {
                # self-heal: cached claude path may exist but be broken (e.g. after a CLI reinstall)
                try {
                    $fresh = Resolve-ClaudeExe -NoCache
                    if ($fresh -and ($fresh -ne $claude)) { $claude = $fresh; $refreshed = $true }
                } catch { }
            }
            if (-not $ok -and $attempts -lt 3) { Start-Sleep -Seconds 90 }
        }

        if ($ok -and $refreshed) {
            try {
                $st = Read-State
                if ($st) { $st.claude = $claude; Write-State $st } else { Write-State @{ claude = $claude } }
            } catch { }
        }

        # the ping's own rate_limit_event: refresh the cache the panel strip and
        # the chase read with the newest reading (a usage-limit failure carries
        # one too: worth showing)
        $windows = $null
        if ($rlInfo) { try { $windows = ConvertFrom-RateLimitInfo $rlInfo } catch { } }
        if ($windows) { Write-RateLimitCache $windows }
        # the anchor is judged on the SUCCESSFUL attempt's own reading only: a
        # failed attempt's could describe a window that has ended since
        $okWindows = $null
        if ($rlOk) { try { $okWindows = ConvertFrom-RateLimitInfo $rlOk } catch { } }

        $entry = @{ ev = 'fire'; ok = $ok; attempts = $attempts; ms = $ms; cost = $cost }
        if (-not $ok) { $entry.err = $errText; $entry.kind = $kind }
        if ($ok) {
            $rlEnd = $null
            if ($okWindows -and $okWindows.five_hour -and $okWindows.five_hour.resets_at) {
                try { $rlEnd = [DateTimeOffset]::FromUnixTimeSeconds([long]$okWindows.five_hour.resets_at).LocalDateTime } catch { }
            }
            $truth = Test-AnchorFromWindow $fireStart $rlEnd
            if ($null -ne $truth) {
                # measured, not guessed: blind spots of the local guess (phone,
                # claude.ai, a stale tap) no longer matter
                $entry.anchored = $truth; $entry.anchor_src = 'ratelimit'
                $entry.resets_at = $rlEnd.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
                # a chase lands 2 minutes after the REAL end, whatever the tap last saw
                $knownEnd = $rlEnd
            } else {
                $entry.anchored = Test-FreshAnchor $fireStart $lastAct $knownEnd $ownAnchor
                $entry.anchor_src = 'activity'
            }
            if ($lastAct) { $entry.last_local_activity = $lastAct.ToString('yyyy-MM-dd HH:mm') }
        }
        Write-Log $entry
        $anch = $null
        if ($entry.ContainsKey('anchored')) { $anch = $entry.anchored }
        $chase = $null
        if ($ok -and ($anch -eq $false)) {
            # the schedule wanted an anchor now and the account was busy: try
            # again the minute that window expires (Get-ChasePlan)
            try { $chase = Invoke-Chase $fireStart $lastAct $knownEnd }
            catch { Write-Log @{ ev = 'chase-skip'; reason = ('error: ' + $_.Exception.Message) } }
        }
        $extra = ''
        if ($chase -and $chase.at) { $extra = ' - follow-up preheat at ' + $chase.at.ToString('HH:mm') }
        Send-Toast $ok $anch $kind $extra

        if ($OnMac -and $env:CLAUDE_PREHEAT_SELF -and ($env:CLAUDE_PREHEAT_SELF -like ($TaskOncePrefix + '-*'))) {
            # a spent one-shot must not survive to fire again next year. Delete
            # only the plist here: bootout of our own label would SIGTERM this
            # very process. Remove-StaleOnceJobs boots the orphaned label out at
            # the next fire/apply.
            try {
                Remove-Item (Join-Path $LaunchAgentDir ((ConvertTo-LaunchdLabel $env:CLAUDE_PREHEAT_SELF) + '.plist')) `
                    -Force -ErrorAction SilentlyContinue
            } catch { }
        }
    } finally {
        if ($ownLock) { Remove-Item $FireLock -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-Once($fireAt, $label, [switch]$NoWake) {
    if ($fireAt -le (Get-Date)) { throw "fire time $fireAt is in the past" }
    # InvariantCulture: on macOS the name IS the schedule (Get-JobNextRun decodes
    # it with the invariant calendar), so a Buddhist year here would decode wrong
    $name = '{0}-{1}' -f $TaskOncePrefix, $fireAt.ToString('yyyyMMdd-HHmm', [System.Globalization.CultureInfo]::InvariantCulture)
    Register-PreheatJob -Name $name -At $fireAt -NoWake:$NoWake -ScriptArgs @('fire', '-Job', $name)
    Write-Log @{ ev = 'schedule-once'; fireAt = $fireAt.ToString('s'); label = $label }
    Write-Host ('one-shot registered: fire at {0}  ({1})' -f $fireAt.ToString('yyyy-MM-dd HH:mm'), $label)
}

function Get-NextOccurrence([string]$hhmm) {
    $t    = [datetime]::ParseExact($hhmm, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
    $cand = (Get-Date).Date + $t.TimeOfDay
    if ($cand -le (Get-Date)) { $cand = $cand.AddDays(1) }
    $cand
}

function Invoke-Status {
    Write-Host ''
    Write-Host '=== claude-preheat ==='
    $last = Get-LastLocalActivity
    if ($last) {
        $gapH = ((Get-Date) - $last).TotalHours
        if ($gapH -lt $WindowHours) {
            Write-Host ('activity : last local use {0} ({1:n1}h ago) - a window is likely active; exact reset: /usage' -f $last.ToString('MM-dd HH:mm'), $gapH)
        } else {
            Write-Host ('activity : quiet for {0:n1}h - next message (or preheat) anchors a fresh window' -f $gapH)
        }
    } else {
        Write-Host 'activity : no local transcripts found'
    }
    Write-Host ''
    Write-Host '-- scheduled preheats --'
    $tasks = @(Get-PreheatJobs)
    if ($tasks.Count -gt 0) {
        foreach ($t in $tasks) {
            $nextTxt = '{0}' -f $t.next
            if (Test-SpentOnce $t (Get-Date)) { $nextTxt += '  (spent - removed at the next fire or apply)' }
            Write-Host ('{0}  next: {1}' -f $t.name.PadRight(40), $nextTxt)
        }
        # a moved or renamed repo leaves the jobs registered and still showing a
        # next run, while every fire is a silent no-op - the one failure mode
        # status could not see before
        $broken = @($tasks | Where-Object { $_.script -and (-not (Test-Path $_.script)) })
        if ($broken.Count -gt 0) {
            foreach ($b in $broken) {
                Write-Host ('! {0} points at {1} which no longer exists (repo moved or renamed?)' -f $b.name, $b.script) -ForegroundColor Red
            }
            Write-Host 'fix: run install.ps1 again, then preheat apply' -ForegroundColor Red
        }
        # the other silent no-op: the host shell baked into the job is gone (a
        # Store pwsh update replaced its versioned folder). The vbs shim now
        # exits non-zero for it, but Task Scheduler's own view still says Ready.
        $noShell = @($tasks | Where-Object { $_.shell -and (-not (Test-Path $_.shell)) })
        if ($noShell.Count -gt 0) {
            foreach ($b in $noShell) {
                Write-Host ('! {0} runs {1} which no longer exists (PowerShell updated?)' -f $b.name, $b.shell) -ForegroundColor Red
            }
            Write-Host 'fix: preheat apply (re-registers the jobs with the current shell)' -ForegroundColor Red
        }
    } else {
        Write-Host '(none - run: preheat apply)'
    }
    Write-Host ''
    Write-Host '-- recent events --'
    if (Test-Path $LogPath) {
        Get-Content $LogPath -Encoding UTF8 | Select-Object -Last 8 | ForEach-Object {
            try {
                $e = $_ | ConvertFrom-Json
                if ($e.ev -eq 'fire') {
                    $flag = if ($e.ok) { 'OK  ' } else { 'FAIL' }
                    $anch = ''
                    if ($e.PSObject.Properties['anchored']) {
                        $anch = if ($e.anchored) { 'anchored NEW window' } else {
                            # say WHEN the account was last busy: that is the whole explanation
                            $at = if ($e.PSObject.Properties['last_local_activity'] -and $e.last_local_activity) { ' at ' + [string]$e.last_local_activity } else { ' <5h before fire' }
                            'local activity' + $at + ' - window was still open, ping landed in it (no new window)'
                        }
                    }
                    if (-not $e.ok -and $e.PSObject.Properties['err'] -and $e.err) {
                        # a FAIL line that does not say why sends the user to the raw jsonl
                        $k = if ($e.PSObject.Properties['kind'] -and $e.kind) { [string]$e.kind } else { 'error' }
                        $anch = '{0}: {1}' -f $k, ([string]$e.err).Substring(0, [Math]::Min(100, ([string]$e.err).Length))
                    }
                    Write-Host ('[{0}] fire {1} attempts={2} {3}ms  {4}' -f $e.ts, $flag, $e.attempts, $e.ms, $anch)
                } elseif ($e.ev -eq 'schedule-once') {
                    $lbl = ''
                    if ($e.PSObject.Properties['label'] -and $e.label) {
                        # journal vocabulary -> what the user sees
                        $lbl = switch -Regex ([string]$e.label) {
                            '^chase ratelimits' { ' (follow-up preheat, exact reset)'; break }
                            '^chase estimate'   { ' (follow-up preheat, estimated reset)'; break }
                            default             { ' (' + [string]$e.label + ')' }
                        }
                    }
                    # format here: pwsh 7 hands fireAt back as a DateTime, 5.1 as the string
                    $fa = ConvertTo-LocalTime $e.fireAt
                    $faTxt = if ($fa) { $fa.ToString('MM-dd HH:mm') } else { [string]$e.fireAt }
                    Write-Host ('[{0}] one-shot scheduled for {1}{2}' -f $e.ts, $faTxt, $lbl)
                } elseif ($e.ev -eq 'chase-skip') {
                    Write-Host ('[{0}] chase skipped: {1}' -f $e.ts, $e.reason)
                } else {
                    Write-Host ('[{0}] {1}' -f $e.ts, $e.ev)
                }
            } catch { }
        }
    } else {
        Write-Host '(no log yet)'
    }
    Write-Host ''
    # same warning apply gives: a fire that cannot wake the PC is a silent no-show
    Test-WakeTimers
}

function Invoke-StatusJson {
    # single compact JSON object for scripts -- nothing else on stdout
    $last = Get-LastLocalActivity
    $lastIso = $null
    if ($last) { $lastIso = $last.ToString('yyyy-MM-ddTHH:mm:ss') }
    $tasks = @()
    $broken = @()
    foreach ($t in @(Get-PreheatJobs)) {
        $next = $null
        if ($t.next) { $next = $t.next.ToString('yyyy-MM-ddTHH:mm:ss') }
        $tasks += @{ name = $t.name; next = $next; spent = [bool](Test-SpentOnce $t (Get-Date)) }
        if (($t.script -and (-not (Test-Path $t.script))) -or ($t.shell -and (-not (Test-Path $t.shell)))) { $broken += $t.name }
    }
    $out = @{ lastActivity = $lastIso; tasks = $tasks; brokenTasks = @($broken) }
    ConvertTo-Json -InputObject $out -Compress -Depth 6
}

# ---------- learn: schedule suggestions + waste report from prompt history ----------

function Get-HistoryTimestamps([int]$days = 30) {
    # ~\.claude\history.jsonl logs one line per user prompt with an epoch-ms
    # timestamp - the cheapest full activity record there is (transcripts
    # would mean reading hundreds of MB for the same numbers)
    $h = Join-Path (Join-Path (Get-ClaudeHome) '.claude') 'history.jsonl'
    $out = New-Object System.Collections.Generic.List[datetime]
    if (-not (Test-Path $h)) { return ,$out }
    $cut = (Get-Date).AddDays(-$days)
    try {
        foreach ($line in [System.IO.File]::ReadLines($h)) {
            if ($line -notmatch '"timestamp"\s*:\s*(\d+)') { continue }
            $n = [double]$Matches[1]
            if ($n -gt 1e12) { $n = $n / 1000 }
            $t = [DateTimeOffset]::FromUnixTimeSeconds([long]$n).LocalDateTime
            if ($t -ge $cut) { [void]$out.Add($t) }
        }
    } catch { }
    $out.Sort()
    ,$out
}

function Get-WindowStats($stamps) {
    # reconstruct 5h windows the way the account anchors them: the first
    # prompt while no window is active opens one; everything within 5h of the
    # anchor rides it; the next prompt after expiry anchors the next
    $wins = @()
    $anchor = $null; $lastIn = $null
    foreach ($t in $stamps) {
        if ($anchor -and ($t -lt $anchor.AddHours($WindowHours))) { $lastIn = $t; continue }
        if ($anchor) { $wins += , @{ anchor = $anchor; last = $lastIn } }
        $anchor = $t; $lastIn = $t
    }
    if ($anchor) { $wins += , @{ anchor = $anchor; last = $lastIn } }
    # plain return (callers wrap in @()): a `,`-wrapped return here would
    # double-wrap and hand Where-Object one 54-anchor blob instead of 54 windows
    $wins
}

function Get-MedianTimeOfDay($times) {
    if (-not $times -or $times.Count -eq 0) { return $null }
    $sorted = @($times | Sort-Object { $_.TotalMinutes })
    $sorted[[int][Math]::Floor(($sorted.Count - 1) / 2)]
}

function Get-LearnReport($stamps, $now) {
    $wins = @(Get-WindowStats $stamps)
    $byDay = @{}
    foreach ($w in $wins) {
        $d = $w.anchor.DayOfWeek.ToString().Substring(0, 3)
        if (-not $byDay[$d]) { $byDay[$d] = New-Object System.Collections.Generic.List[object] }
        [void]$byDay[$d].Add($w.anchor.TimeOfDay)
    }
    $dayOrder = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun')
    $days = @()
    foreach ($d in $dayOrder) {
        if (-not $byDay[$d]) { continue }
        $ts = $byDay[$d]
        $median = Get-MedianTimeOfDay $ts
        $suggest = $null
        $suggestDay = $d
        if (($ts.Count -ge 2) -and $median) {
            # reset ~1h after the typical start: early work rides the old
            # window's tail, the bulk of the session gets a fresh one
            $m = [Math]::Round(($median.TotalMinutes + 60) / 30) * 30
            if ($m -ge 1440) {
                # a start near midnight pushes the reset past 24:00 - the rule
                # must carry to the NEXT weekday, or Get-FireSpecs anchors the
                # window a full day early (fire ~23h before the user starts)
                $m = $m - 1440
                $suggestDay = $dayOrder[(([array]::IndexOf($dayOrder, $d) + 1) % 7)]
            }
            $suggest = ([timespan]::FromMinutes($m)).ToString('hh\:mm')
        }
        $days += , @{ day = $d; samples = $ts.Count; median = $median.ToString('hh\:mm'); suggest = $suggest; suggestDay = $suggestDay }
    }
    # utilization, last 7 days: prompts under-count long agent runs, so each
    # window gets a 30-min grace past its last prompt - still an ESTIMATE
    $wk = @($wins | Where-Object { $_.anchor -ge $now.AddDays(-7) })
    $engaged = 0.0; $total = 0.0
    foreach ($w in $wk) {
        $end = $w.anchor.AddHours($WindowHours)
        if ($end -gt $now) { $end = $now }
        $winH = ($end - $w.anchor).TotalHours
        if ($winH -le 0) { continue }
        $total += $winH
        $e = (($w.last - $w.anchor).TotalHours) + 0.5
        if ($e -gt $winH) { $e = $winH }
        $engaged += $e
    }
    $pct = $null
    if ($total -gt 0) { $pct = [int][Math]::Round(100 * $engaged / $total) }
    @{
        days  = $days
        waste = @{ windows = $wk.Count; engagedH = [Math]::Round($engaged, 1); totalH = [Math]::Round($total, 1); usedPct = $pct }
    }
}

function New-LearnedConfig($Existing, $Rules) {
    # PURE - the schedule.json 'learn auto' writes: new rules, every other key
    # of the existing file kept as is (proxy, "chase": false, ...). Rebuilding
    # from a fixed key list used to drop "chase": false silently.
    $out = [ordered]@{
        _readme = 'days: Mon..Sun | reset = HH:mm target reset time (previous 5h window expiry); fire time auto = reset - 5h | edit then run: preheat apply | chase: false = no follow-up ping when a scheduled preheat lands in a running window'
        proxy   = ''
    }
    if ($Existing) {
        foreach ($p in $Existing.PSObject.Properties) {
            if ($p.Name -eq 'rules') { continue }
            $out[$p.Name] = $p.Value
        }
    }
    $out['rules'] = @($Rules)
    $out
}

function Invoke-Learn {
    $stamps = Get-HistoryTimestamps 30
    if ($stamps.Count -eq 0) {
        if ($Json) { ConvertTo-Json -InputObject @{ days = @(); waste = $null } -Compress }
        else {
            # real path (platform separators), and say which of the two states it is:
            # a missing file reads very differently from "nothing recent in it"
            $h = Join-Path (Join-Path (Get-ClaudeHome) '.claude') 'history.jsonl'
            if (Test-Path $h) { Write-Host ('no prompts in the last 30 days ({0}) - nothing to learn from yet' -f $h) }
            else { Write-Host ('no prompt history found ({0}) - nothing to learn from' -f $h) }
        }
        return
    }
    $rep = Get-LearnReport $stamps (Get-Date)
    if ($Json) { ConvertTo-Json -InputObject $rep -Compress -Depth 6; return }

    Write-Host ''
    Write-Host '=== preheat learn (last 30 days of local prompts) ===' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'day  windows  median-start  suggested-reset'
    foreach ($d in $rep.days) {
        $s = $d.suggest; if (-not $s) { $s = '(need >=2 windows)' }
        Write-Host ('{0}  {1}  {2}         {3}' -f $d.day, ([string]$d.samples).PadLeft(7), $d.median, $s)
    }
    $w = $rep.waste
    if ($w -and $w.windows -gt 0) {
        Write-Host ''
        Write-Host ('last 7 days: {0} window(s) opened, ~{1}h engaged of {2}h window time ({3}% used, estimate)' -f `
            $w.windows, $w.engagedH, $w.totalH, $w.usedPct)
        # say whose numbers these are: history.jsonl records prompts YOU typed,
        # so a preheat ping never appears here and never inflates the report
        Write-Host '  (estimate from your own prompts - preheat pings are not in this history)'
    }
    $groups = [ordered]@{}
    foreach ($d in $rep.days) {
        if (-not $d.suggest) { continue }
        if (-not $groups.Contains($d.suggest)) { $groups[$d.suggest] = @() }
        $groups[$d.suggest] += $d.suggestDay   # carries past midnight to the next weekday
    }
    if ($groups.Count -eq 0) {
        Write-Host ''
        Write-Host 'not enough data for suggestions yet (a weekday needs >=2 observed windows)'
        return
    }
    Write-Host ''
    Write-Host 'suggested rules:'
    foreach ($k in $groups.Keys) { Write-Host ('  {0}: reset {1}' -f ($groups[$k] -join ','), $k) }

    if ($Arg -ne 'auto') {
        Write-Host ''
        Write-Host 'apply them: preheat learn auto   (backs up schedule.json, writes these rules, runs apply)'
        return
    }
    # auto: write + apply; days without a suggestion get no rule (no observed
    # rhythm -> nothing worth pre-warming)
    $c0  = $null
    $bak = $null
    try {
        if (Test-Path $ConfigPath) {
            $probe = Get-Content $ConfigPath -Raw -Encoding UTF8
            if ($probe) {
                # timestamped, not a fixed .bak: the second learn auto used to
                # overwrite the only copy of the schedule the user hand-wrote
                $bak = Backup-File $ConfigPath
                $c0 = $probe | ConvertFrom-Json
            }
        }
    } catch { }
    $rulesOut = @()
    foreach ($k in $groups.Keys) { $rulesOut += [ordered]@{ days = @($groups[$k]); reset = [string]$k } }
    Write-Utf8NoBom $ConfigPath (ConvertTo-Json -InputObject (New-LearnedConfig $c0 $rulesOut) -Depth 8)
    Write-Host ''
    if ($bak) { Write-Host ('schedule.json written (previous copy saved as {0}) - applying:' -f (Split-Path $bak -Leaf)) }
    else { Write-Host 'schedule.json written - applying:' }
    Invoke-Apply
}

function Invoke-Off {
    Wait-FireLock
    Remove-PreheatJobs 'ClaudePreheat*'
    Write-Log @{ ev = 'off' }
    Write-Host 'all preheat tasks removed'
}

function ConvertTo-BashPath([string]$p) {
    # statusLine commands run under sh: C:\x\y -> /c/x/y. The result gets
    # embedded inside double quotes, which stop word-splitting but NOT $ or
    # backtick expansion - escape those so a path like C:\tools\$dev survives
    $x = $p -replace '\\', '/'
    if ($x -match '^([A-Za-z]):(.*)$') { $x = '/' + $Matches[1].ToLower() + $Matches[2] }
    $x -replace '([$"`\\])', '\$1'
}

function Invoke-StatusLineSetup {
    # Wire statusline-tap.cjs into the user's statusLine (or remove it again).
    # The tap is a pure pipe stage - stdin reaches the original command
    # byte-identical - so wrapping is safe for ANY existing command:
    #   "<node>" "<tap>" | ( <original command> )
    # With no statusLine configured at all, the tap runs --solo and renders a
    # minimal usage line itself. Original settings are backed up AND kept in a
    # sidecar so 'off' restores them exactly.
    $onOff = $Arg
    if ($onOff -notin @('on', 'off')) { Write-Host 'usage: preheat statusline on | off'; return }
    $tap = Join-Path $Root 'statusline-tap.cjs'
    $sidecar = Join-Path $Root 'statusline-original.json'
    $claudeDir = Join-Path (Get-ClaudeHome) '.claude'
    $candFiles = @((Join-Path $claudeDir 'settings.local.json'), (Join-Path $claudeDir 'settings.json'))
    $readCmd = {
        param($path)
        if (-not (Test-Path $path)) { return $null }
        try {
            $j = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.PSObject.Properties['statusLine'] -and $j.statusLine -and $j.statusLine.PSObject.Properties['command']) {
                return [string]$j.statusLine.command
            }
        } catch { }
        $null
    }
    # the tap may live in EITHER settings file (whichever had the statusLine
    # when it was installed) - both on and off must look at both, or an off
    # after the other file gained a statusLine becomes a silent no-op while
    # the wrapped file stays wired (found by review 2026-08-15)
    $tapFile = $null
    foreach ($cand in $candFiles) {
        $c = & $readCmd $cand
        if ($c -and ($c -like '*statusline-tap.cjs*')) { $tapFile = $cand; break }
    }

    if ($onOff -eq 'off') {
        $sFile = $null
        if (Test-Path $sidecar) {
            # the sidecar remembers exactly which file was wrapped - trust it
            # as long as that file still carries the tap
            try {
                $sc = Get-Content $sidecar -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($sc.PSObject.Properties['file'] -and $sc.file) {
                    $c = & $readCmd ([string]$sc.file)
                    if ($c -and ($c -like '*statusline-tap.cjs*')) { $sFile = [string]$sc.file }
                }
            } catch { }
        }
        if (-not $sFile) { $sFile = $tapFile }
        if (-not $sFile) { Write-Host 'statusline tap is not installed - nothing to do'; return }
        $json = $null
        try { $json = Get-Content $sFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
            Write-Host ('cannot parse {0} - fix it first, nothing was changed' -f $sFile); return
        }
        $oldCmd = [string]$json.statusLine.command
        $restore = $null
        if (Test-Path $sidecar) {
            try { $restore = Get-Content $sidecar -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        }
        # decide FIRST, touch the file only once a restore is certain: the old
        # third branch dropped the whole statusLine key, so a hand-edited
        # command cost the user the statusline they had written themselves
        $newCmd = $null
        if ($restore -and $restore.PSObject.Properties['command'] -and $restore.command) {
            $newCmd = [string]$restore.command
        } elseif ($oldCmd -match '^"[^"]+" "[^"]*statusline-tap\.cjs" \| \( (.*) \)$') {
            $newCmd = $Matches[1]   # sidecar lost: unwrap
        } else {
            Write-Host ('cannot restore automatically: the sidecar is gone and the statusLine command in {0} was edited by hand - remove the statusline-tap.cjs part yourself (a timestamped backup is written on every change); nothing was changed' -f $sFile)
            return
        }
        $null = Backup-File $sFile
        $json.statusLine.command = $newCmd
        Write-Utf8NoBom $sFile (ConvertTo-Json -InputObject $json -Depth 20)
        Remove-Item $sidecar -ErrorAction SilentlyContinue
        Write-Host ('statusline tap removed from {0} (backup written)' -f $sFile)
        return
    }

    # --- on ---
    if ($tapFile) { Write-Host ('statusline tap is already installed (in {0})' -f $tapFile); return }
    # target: whichever file currently carries a statusLine, local preferred;
    # neither -> settings.local.json gets a solo tap
    $sFile = $null
    foreach ($cand in $candFiles) {
        if (& $readCmd $cand) { $sFile = $cand; break }
    }
    if (-not $sFile) { $sFile = $candFiles[0] }
    $json = $null
    if (Test-Path $sFile) {
        try { $json = Get-Content $sFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
            Write-Host ('cannot parse {0} - fix it first, nothing was changed' -f $sFile); return
        }
    }
    if (-not $json) { $json = [pscustomobject]@{} }
    $oldCmd = & $readCmd $sFile
    # reuse the node the user's own command already points at (the statusline
    # environment may not have node on PATH); fall back to PATH lookup
    $node = 'node'
    if ($oldCmd -and ($oldCmd -match '"([^"]*node(\.exe)?)"')) { $node = $Matches[1] }
    elseif (Get-Command node -ErrorAction SilentlyContinue) { $node = ConvertTo-BashPath (Get-Command node).Source }
    if ($node -eq 'node') {
        # writing a bare "node" only works if the statusline shell happens to
        # have it on PATH - it usually does not, and the breakage is silent
        Write-Host 'node was not found on PATH and your current statusline does not name one - install Node.js (or add it to PATH) and re-run; nothing was changed'
        return
    }
    $tapBash = ConvertTo-BashPath $tap
    if ($oldCmd) {
        $newCmd = ('"{0}" "{1}" | ( {2} )' -f $node, $tapBash, $oldCmd)
    } else {
        $newCmd = ('"{0}" "{1}" --solo' -f $node, $tapBash)
    }
    $null = Backup-File $sFile
    @{ file = $sFile; command = $oldCmd } | ConvertTo-Json | Set-Content -Path $sidecar -Encoding UTF8
    if ($json.PSObject.Properties['statusLine'] -and $json.statusLine) {
        $json.statusLine | Add-Member -NotePropertyName command -NotePropertyValue $newCmd -Force
        if (-not ($json.statusLine.PSObject.Properties['type'])) {
            $json.statusLine | Add-Member -NotePropertyName type -NotePropertyValue 'command' -Force
        }
    } else {
        $json | Add-Member -NotePropertyName statusLine -NotePropertyValue ([pscustomobject]@{ type = 'command'; command = $newCmd }) -Force
    }
    # BOM-less: 5.1's Set-Content -Encoding UTF8 would stamp one, and BOM-poisoned
    # settings JSON breaks strict parsers
    Write-Utf8NoBom $sFile (ConvertTo-Json -InputObject $json -Depth 20)
    Write-Host ('statusline tap installed in {0} (backup + sidecar written)' -f $sFile)
    Write-Host 'takes effect on the next statusline render; rate limits land in state-ratelimits.json'
    Write-Host 'undo anytime: preheat statusline off'
}

switch -Regex ($Command) {
    '^apply$'  { Invoke-Apply; break }
    '^fire$'   { Invoke-Fire; break }
    '^status$' { if ($Json) { Invoke-StatusJson } else { Invoke-Status }; break }
    '^learn$'  { Invoke-Learn; break }
    '^off$'    { Invoke-Off; break }
    '^statusline$' { Invoke-StatusLineSetup; break }
    '^at$'     {
        if (-not $Arg) { throw 'usage: preheat at HH:mm' }
        Invoke-Once (Get-NextOccurrence $Arg) ('at ' + $Arg)
        break
    }
    '^reset$'  {
        if (-not $Arg) { throw 'usage: preheat reset HH:mm' }
        $t = (Get-NextOccurrence $Arg).AddHours(-$WindowHours)
        if ($t -le (Get-Date)) {
            Write-Host ('requested reset {0} unreachable today (fire time already past) - scheduling for tomorrow' -f $Arg)
            $t = $t.AddDays(1)
        }
        Invoke-Once $t ('reset ' + $Arg)
        break
    }
    '^\+\d+[hm]$' {
        $null = $Command -match '^\+(\d+)([hm])$'
        $n = [int]$Matches[1]
        $t = if ($Matches[2] -eq 'h') { (Get-Date).AddHours($n) } else { (Get-Date).AddMinutes($n) }
        Invoke-Once $t $Command
        break
    }
    default {
        Write-Host 'usage: preheat apply | status [-Json] | learn [auto] | at HH:mm | reset HH:mm | +Nh | +Nm | fire | statusline on|off | off'
    }
}
