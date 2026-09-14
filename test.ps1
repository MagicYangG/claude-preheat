#Requires -Version 5.1
<#
claude-preheat self-test: preheat scheduling, the local panel, the statusline tap.

Run:  ./test.ps1            (add -Verbose for per-case detail)
Exit: 0 = all passed, 1 = at least one failure.

Costs nothing and touches nothing that matters:
  - no `claude` call, so zero quota and no usage window is anchored
  - schedule.json, the real journal and the registered scheduled tasks are
    never written; the panel is started on a spare port and killed again
  - all fixtures live under a temp directory that is removed at the end

What CANNOT be automated here (needs a real account and real waiting):
  1. that a headless ping anchors a NEW window when none is active   <- the
     load-bearing assumption of the whole tool; verify via /usage after a
     scheduled preheat that fires following 5h+ of true inactivity
  2. that a ping into an ALREADY-ACTIVE window is a harmless no-op
  3. that a rejected probe consumes no quota
  4. that -WakeToRun really wakes this machine from sleep
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Repo = $PSScriptRoot
$Tmp  = Join-Path ([System.IO.Path]::GetTempPath()) ('clr-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Tmp -Force | Out-Null

$script:Pass = 0
$script:Fail = 0
$script:Skip = 0
$script:Failures = @()
$script:Skipped = @()

function Test-Case([string]$name, [scriptblock]$body) {
    try {
        $result = & $body
        if ($result -eq $true) {
            $script:Pass++
            Write-Verbose ("PASS  " + $name)
        } elseif (($result -is [string]) -and ($result -eq 'SKIP')) {
            # a case that cannot run here (no node, no registered job) used to
            # `return $true` and the summary said ALL PASS over cases nobody ran.
            # PREHEAT_STRICT=1 turns that back into a failure where it can run.
            if ($env:PREHEAT_STRICT -eq '1') {
                $script:Fail++
                $script:Failures += ('{0}   (skipped, but PREHEAT_STRICT=1)' -f $name)
                Write-Host ("FAIL  " + $name + "  [skipped under PREHEAT_STRICT]") -ForegroundColor Red
            } else {
                $script:Skip++
                $script:Skipped += $name
                Write-Host ("SKIP  " + $name) -ForegroundColor DarkYellow
            }
        } else {
            $script:Fail++
            $script:Failures += ('{0}   (returned: {1})' -f $name, $result)
            Write-Host ("FAIL  " + $name) -ForegroundColor Red
        }
    } catch {
        $script:Fail++
        $script:Failures += ('{0}   (threw: {1})' -f $name, $_.Exception.Message)
        Write-Host ("FAIL  " + $name + "  [threw] " + $_.Exception.Message) -ForegroundColor Red
    }
}

function New-Fixture([string]$name, [string[]]$lines) {
    $p = Join-Path $Tmp $name
    Set-Content -Path $p -Value ($lines -join "`n") -Encoding UTF8
    $p
}

# record builders that mirror the real transcript shapes
function Rec-User([string]$text, [string]$tsUtc, [string]$cwd) {
    # a plainly typed message stores content as a STRING, not as text items
    $c = '{"type":"user","message":{"role":"user","content":"' + $text + '"},"timestamp":"' + $tsUtc + '"'
    if ($cwd) { $c += ',"cwd":"' + $cwd + '"' }
    $c + '}'
}
function Rec-Assistant([string]$text, [string]$tsUtc) {
    '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"' + $text + '"}]},"timestamp":"' + $tsUtc + '"}'
}
function Rec-Bookkeeping([string]$subtype, [string]$tsUtc) {
    # Claude Code appends these to an OPEN-BUT-IDLE session: no API call happened
    if ($subtype -eq 'attachment') { return '{"type":"attachment","timestamp":"' + $tsUtc + '"}' }
    '{"type":"system","subtype":"' + $subtype + '","timestamp":"' + $tsUtc + '"}'
}

Write-Host ''
Write-Host '=== claude-preheat self-test ===' -ForegroundColor Cyan

# ---------------------------------------------------------------- preheat.ps1
# dot-source inside its own scope so its helpers stay out of the top scope;
# '__selftest__' falls through to the usage branch
& {
    . (Join-Path $Repo 'preheat.ps1') '__selftest__' 6>$null | Out-Null
    Write-Host ''
    Write-Host '-- preheat: reset -> fire derivation --'

    Test-Case 'reset 08:40 -> fire 03:40, same day' {
        $s = @(Get-FireSpecs ([pscustomobject]@{ rules = @([pscustomobject]@{ days = @('Mon'); reset = '08:40' }) }))
        ($s[0].FireTime -eq [timespan]::Parse('03:40:00')) -and ($s[0].Days[0] -eq 'Monday')
    }
    Test-Case 'reset 12:30 -> fire 07:30, same day' {
        $s = @(Get-FireSpecs ([pscustomobject]@{ rules = @([pscustomobject]@{ days = @('Wed'); reset = '12:30' }) }))
        ($s[0].FireTime -eq [timespan]::Parse('07:30:00')) -and ($s[0].Days[0] -eq 'Wednesday')
    }
    Test-Case 'reset 02:00 -> fire 21:00 and day shifts back (Mon -> Sunday)' {
        $s = @(Get-FireSpecs ([pscustomobject]@{ rules = @([pscustomobject]@{ days = @('Mon'); reset = '02:00' }) }))
        ($s[0].FireTime -eq [timespan]::Parse('21:00:00')) -and ($s[0].Days[0] -eq 'Sunday')
    }
    Test-Case 'reset 05:00 -> fire 00:00 exactly, NO day shift' {
        $s = @(Get-FireSpecs ([pscustomobject]@{ rules = @([pscustomobject]@{ days = @('Wed'); reset = '05:00' }) }))
        ($s[0].FireTime -eq [timespan]::Zero) -and ($s[0].Days[0] -eq 'Wednesday')
    }
    Test-Case 'day shift wraps Sunday -> Saturday' {
        $s = @(Get-FireSpecs ([pscustomobject]@{ rules = @([pscustomobject]@{ days = @('Sun'); reset = '01:00' }) }))
        $s[0].Days[0] -eq 'Saturday'
    }
    Test-Case 'multi-day rule keeps every day' {
        $s = @(Get-FireSpecs ([pscustomobject]@{ rules = @([pscustomobject]@{ days = @('Mon', 'Tue', 'Wed', 'Thu'); reset = '08:40' }) }))
        $s[0].Days.Count -eq 4
    }
    Test-Case 'unknown day name throws' {
        try {
            Get-FireSpecs ([pscustomobject]@{ rules = @([pscustomobject]@{ days = @('Xyz'); reset = '08:40' }) }) | Out-Null
            $false
        } catch { $true }
    }

    Write-Host '-- preheat: next occurrence --'
    Test-Case 'a time later today resolves to today' {
        $future = (Get-Date).AddHours(2).ToString('HH:mm')
        $n = Get-NextOccurrence $future
        ($n -gt (Get-Date)) -and (($n - (Get-Date)).TotalHours -lt 24)
    }
    Test-Case 'a time already past resolves to tomorrow (never the past)' {
        $past = (Get-Date).AddHours(-2).ToString('HH:mm')
        (Get-NextOccurrence $past) -gt (Get-Date)
    }
    Test-Case 'a culture whose time separator is not ":" still reads HH:mm' {
        # ParseExact with the CURRENT culture reads ':' as "that culture's time
        # separator" - fi-FI uses '.', so on a Finnish desktop every reset in
        # schedule.json threw and no task was ever registered
        $th = [System.Threading.Thread]::CurrentThread
        $c0 = $th.CurrentCulture
        $u0 = $th.CurrentUICulture
        try {
            $fi = [System.Globalization.CultureInfo]::GetCultureInfo('fi-FI')
            $th.CurrentCulture = $fi
            $th.CurrentUICulture = $fi
            $n = Get-NextOccurrence '08:40'
            $s = @(Get-FireSpecs ([pscustomobject]@{ rules = @([pscustomobject]@{ days = @('Mon'); reset = '08:40' }) }))
            ($n.Hour -eq 8) -and ($n.Minute -eq 40) -and ($s[0].FireTime -eq [timespan]::new(3, 40, 0))
        } finally {
            $th.CurrentCulture = $c0
            $th.CurrentUICulture = $u0
        }
    }

    Write-Host '-- preheat: ping verdict (pure, costs nothing) --'
    Test-Case 'exit 0 with an is_error payload is a FAILURE, and an auth one' {
        # judging a ping by its exit code alone logged an expired login as a
        # good preheat, day after day, while no window was ever anchored
        $r = Test-PingOutput 0 '{"is_error":true,"result":"Not logged in - run /login"}' ''
        (-not $r.ok) -and ($r.kind -eq 'auth')
    }
    Test-Case 'a clean result is a success and carries the cost through' {
        $r = Test-PingOutput 0 '{"total_cost_usd":0.0123,"is_error":false}' ''
        $r.ok -and ([math]::Abs([double]$r.cost - 0.0123) -lt 0.000001) -and ($null -eq $r.kind)
    }
    Test-Case 'a non-zero exit with no output is a plain (non-auth) failure' {
        $r = Test-PingOutput 1 '' ''
        (-not $r.ok) -and ($r.kind -eq 'other')
    }
    Test-Case 'unparseable stdout still counts as success (pre-JSON behaviour)' {
        (Test-PingOutput 0 'hello from claude' '').ok
    }
    Test-Case 'exit 1 with an is_error payload logs the reason, not the JSON head' {
        # the shape of a real fire on a limit-hit account: exit 1, empty stderr,
        # and a payload whose first 400 bytes are zeroed usage counters - the
        # log used to keep those and lose the one line that said why
        $pad = '"usage":{' + ((1..60 | ForEach-Object { '"f{0}":0' -f $_ }) -join ',') + '}'
        $r = Test-PingOutput 1 ('{"type":"result","duration_api_ms":0,' + $pad + ',"is_error":true,"result":"Claude AI usage limit reached|1757062200"}') ''
        (-not $r.ok) -and ($r.err -like 'Claude AI usage limit reached*') -and ($r.kind -eq 'limit')
    }
    Test-Case 'a usage-limit or auth failure is not retried (nothing heals in 90s)' {
        (Get-Content (Join-Path $Repo 'preheat.ps1') -Raw -Encoding UTF8) -match [regex]::Escape("kind -eq 'limit')) { break }")
    }

    Write-Host '-- preheat: fire history (journal reader, pure) --'
    Test-Case 'Get-FireEvents: newest first, fires only, bad lines skipped, err trimmed, max honoured' {
        # the panel's fire-history list reads the journal through this; a
        # synthetic journal exercises every record shape without a single ping
        $j = Join-Path $Tmp 'events.jsonl'
        @(
            '{"ev":"apply","tasks":5,"ts":"2026-09-11T07:10:08-07:00"}',
            '{"ev":"fire","ok":true,"anchored":true,"attempts":1,"ms":10072,"cost":0.028,"last_local_activity":"2026-09-11 09:59","ts":"2026-09-12T04:00:12-07:00"}',
            '{"ev":"fire","ok":true,"anchored":false,"attempts":1,"ms":11126,"cost":0.027,"last_local_activity":"2026-09-12 11:49","ts":"2026-09-12T12:15:13-07:00"}',
            'this line is not json {',
            ('{"ev":"fire","ok":false,"kind":"limit","attempts":1,"ms":3868,"cost":null,"err":"' + ('x' * 300) + '","ts":"2026-09-12T19:45:09-07:00"}'),
            '{"ev":"schedule-once","ts":"2026-09-12T20:05:00-07:00"}'
        ) | Set-Content -Path $j -Encoding UTF8
        $all = @(Get-FireEvents $j 60)
        $two = @(Get-FireEvents $j 2)
        ($all.Count -eq 3) -and ($two.Count -eq 2) -and
            ($all[0].kind -eq 'limit') -and (-not $all[0].ok) -and ($all[0].err.Length -eq 120) -and
            ($all[1].ok) -and ($all[1].anchored -eq $false) -and ($all[1].last_local_activity -eq '2026-09-12 11:49') -and
            ($all[2].anchored -eq $true) -and ($null -eq $all[2].kind)
    }
    Test-Case 'Get-FireEvents on a missing journal is an empty list, not an error' {
        @(Get-FireEvents (Join-Path $Tmp 'no-such-journal.jsonl') 60).Count -eq 0
    }
    Write-Host '-- preheat: anchor inference + chase --'
    $D = { param($s) [datetime]::ParseExact($s, 'yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) }
    Test-Case 'fresh anchor: quiet 5h+, or the tap saw the window end before the fire with no turn after it; never inside a window our own ping opened' {
        $fire = & $D '2026-09-13 15:00'
        (Test-FreshAnchor $fire $null $null) -and
        (Test-FreshAnchor $fire (& $D '2026-09-13 09:59') $null) -and
        (-not (Test-FreshAnchor $fire (& $D '2026-09-13 13:49') $null)) -and
        (Test-FreshAnchor $fire (& $D '2026-09-13 13:49') (& $D '2026-09-13 14:00')) -and
        (-not (Test-FreshAnchor $fire (& $D '2026-09-13 14:30') (& $D '2026-09-13 14:00'))) -and
        (-not (Test-FreshAnchor $fire (& $D '2026-09-13 13:49') (& $D '2026-09-13 17:00'))) -and
        (-not (Test-FreshAnchor $fire (& $D '2026-09-13 09:00') $null (& $D '2026-09-13 12:00'))) -and
        (Test-FreshAnchor $fire (& $D '2026-09-13 09:00') $null (& $D '2026-09-13 09:30'))
    }
    Test-Case 'chase plan: exact end from the tap wins, else last turn + 5h; always 2 minutes after the end' {
        $fire = & $D '2026-09-13 15:00'; $last = & $D '2026-09-13 13:49'; $wk = & $D '2026-09-13 20:30'
        $exact = Get-ChasePlan -FireStart $fire -LastAct $last -KnownEnd (& $D '2026-09-13 16:37') -NextWeekly $wk -RecentAnchor $false -Now $fire
        $est   = Get-ChasePlan -FireStart $fire -LastAct $last -KnownEnd $null -NextWeekly $wk -RecentAnchor $false -Now $fire
        ($exact.source -eq 'ratelimits') -and ($exact.at -eq (& $D '2026-09-13 16:39')) -and
        ($est.source -eq 'estimate') -and ($est.at -eq (& $D '2026-09-13 18:51'))
    }
    Test-Case 'chase plan: a stale tap reading (that window already over) falls back to the estimate' {
        $fire = & $D '2026-09-13 15:00'
        $p = Get-ChasePlan -FireStart $fire -LastAct (& $D '2026-09-13 14:30') -KnownEnd (& $D '2026-09-13 14:00') -NextWeekly $null -RecentAnchor $false -Now $fire
        ($p.source -eq 'estimate') -and ($p.at -eq (& $D '2026-09-13 19:32'))
    }
    Test-Case 'chase plan: skipped when a preheat anchored the running window (no chains), when nothing local ran, or when the next weekly fire comes first' {
        $fire = & $D '2026-09-13 15:00'; $last = & $D '2026-09-13 13:49'
        $a = Get-ChasePlan -FireStart $fire -LastAct $last -KnownEnd $null -NextWeekly $null -RecentAnchor $true -Now $fire
        $b = Get-ChasePlan -FireStart $fire -LastAct $null -KnownEnd $null -NextWeekly $null -RecentAnchor $false -Now $fire
        $c = Get-ChasePlan -FireStart $fire -LastAct $last -KnownEnd $null -NextWeekly (& $D '2026-09-13 18:00') -RecentAnchor $false -Now $fire
        # boundary of the 5-minute lead: estimate chase = 18:51; a weekly fire at 18:55 wins, one at 18:57 does not
        $d1 = Get-ChasePlan -FireStart $fire -LastAct $last -KnownEnd $null -NextWeekly (& $D '2026-09-13 18:55') -RecentAnchor $false -Now $fire
        $d2 = Get-ChasePlan -FireStart $fire -LastAct $last -KnownEnd $null -NextWeekly (& $D '2026-09-13 18:57') -RecentAnchor $false -Now $fire
        ($a.skip -like '*chain*') -and ($b.skip -like '*no local*') -and ($c.skip -like '*comes first*') -and
        ($d1.skip -like '*comes first*') -and ($d2.at -eq (& $D '2026-09-13 18:51'))
    }
    Test-Case 'chase plan: an end already behind us (a slow ping) still lands 2 minutes ahead, never in the past' {
        $fire = & $D '2026-09-13 15:00'
        $p = Get-ChasePlan -FireStart $fire -LastAct (& $D '2026-09-13 10:30') -KnownEnd (& $D '2026-09-13 15:02') -NextWeekly $null -RecentAnchor $false -Now (& $D '2026-09-13 15:04')
        $p.at -eq (& $D '2026-09-13 15:06')
    }
    Test-Case 'recent anchor: an anchored fire inside 5h or a PENDING chase blocks a new chase; an older one, a white fire or a chase that already came due does not' {
        $j = Join-Path $Tmp 'chase-journal.jsonl'
        $before = & $D '2026-09-13 15:00'
        $stamp = { param($s) (& $D $s).ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture) }
        ('{"ev":"fire","ok":true,"anchored":true,"ts":"' + (& $stamp '2026-09-13 12:30') + '"}') | Set-Content -Path $j -Encoding UTF8
        $r1 = Test-RecentPreheatAnchor $before $j
        ('{"ev":"fire","ok":true,"anchored":true,"ts":"' + (& $stamp '2026-09-13 09:30') + '"}') | Set-Content -Path $j -Encoding UTF8
        $r2 = Test-RecentPreheatAnchor $before $j
        ('{"ev":"fire","ok":true,"anchored":false,"ts":"' + (& $stamp '2026-09-13 12:30') + '"}') | Set-Content -Path $j -Encoding UTF8
        $r3 = Test-RecentPreheatAnchor $before $j
        ('{"ev":"schedule-once","fireAt":"2026-09-13T16:38:00","label":"chase ratelimits","ts":"' + (& $stamp '2026-09-13 14:00') + '"}') | Set-Content -Path $j -Encoding UTF8
        $r4 = Test-RecentPreheatAnchor $before $j
        # a chase that came due at 12:00 with no fire record behind it (asleep, signed out) must not block
        ('{"ev":"schedule-once","fireAt":"2026-09-13T12:00:00","label":"chase estimate","ts":"' + (& $stamp '2026-09-13 10:00') + '"}') | Set-Content -Path $j -Encoding UTF8
        $r5 = Test-RecentPreheatAnchor $before $j
        $r1 -and (-not $r2) -and (-not $r3) -and $r4 -and (-not $r5)
    }
    Test-Case 'the chase gate reads what Write-Log actually writes (the stamp round-trips under the current culture)' {
        $LogPath = Join-Path $Tmp 'writer-journal.jsonl'   # shadows the real journal in this scope
        Write-Log @{ ev = 'fire'; ok = $true; anchored = $true; attempts = 1 }
        $seen = Test-RecentPreheatAnchor (Get-Date).AddMinutes(1) $LogPath
        $own  = Get-LastPreheatAnchor $LogPath
        $seen -and $own -and (((Get-Date) - $own).TotalMinutes -lt 2)
    }
    Test-Case 'Get-FireEvents pairs a white fire with the follow-up it booked' {
        $j = Join-Path $Tmp 'events-chase.jsonl'
        $stamp = { param($s) (& $D $s).ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture) }
        @(
            ('{"ev":"fire","ok":true,"anchored":false,"attempts":1,"last_local_activity":"2026-09-12 13:49","ts":"' + (& $stamp '2026-09-12 15:00') + '"}'),
            ('{"ev":"schedule-once","fireAt":"2026-09-12T16:39:00","label":"chase ratelimits","ts":"' + (& $stamp '2026-09-12 15:00') + '"}'),
            ('{"ev":"fire","ok":true,"anchored":true,"attempts":1,"ts":"' + (& $stamp '2026-09-12 16:39') + '"}')
        ) | Set-Content -Path $j -Encoding UTF8
        $ev = @(Get-FireEvents $j 60)
        ($ev.Count -eq 2) -and ($null -eq $ev[0].chase_at) -and ($ev[1].chase_at -eq '2026-09-12 16:39')
    }
    Test-Case 'known window end: read from the tap file as local time; junk or missing file -> null' {
        $f = Join-Path $Tmp 'rl.json'
        $epoch = (New-Object DateTimeOffset (& $D '2026-09-13 16:37')).ToUnixTimeSeconds()
        ('{"capturedAt":"x","rate_limits":{"five_hour":{"used_percentage":18,"resets_at":' + $epoch + '}}}') | Set-Content -Path $f -Encoding UTF8
        $ok = ((Get-KnownWindowEnd $f) -eq (& $D '2026-09-13 16:37')) -and ((Get-KnownWindowEnd $f).Kind -eq 'Local')
        Set-Content -Path $f -Value 'not json' -Encoding UTF8
        $ok -and ($null -eq (Get-KnownWindowEnd $f)) -and ($null -eq (Get-KnownWindowEnd (Join-Path $Tmp 'nope.json')))
    }
    Test-Case 'next weekly fire: from schedule.json, always ahead of the given moment, at reset - 5h' {
        # 11:07 -> fire 06:07: a time no real schedule.json is likely to share, so a fixture path bug shows
        $ConfigPath = New-Fixture 'sched.json' @('{"rules":[{"days":["Mon","Tue","Wed","Thu","Fri","Sat","Sun"],"reset":"11:07"}]}')
        (Get-NextWeeklyFire (& $D '2026-09-13 15:00')) -eq (& $D '2026-09-14 06:07')
    }
    Test-Case 'a spent one-shot is flagged (past next on macOS, NO next on Windows); a pending one, one inside the 3-minute grace, and weekly jobs are not' {
        $now = & $D '2026-09-13 15:00'
        (Test-SpentOnce @{ name = 'ClaudePreheat-Once-20260913-1400'; next = (& $D '2026-09-13 14:00') } $now) -and
        (Test-SpentOnce @{ name = 'ClaudePreheat-Once-20260913-1400'; next = $null } $now) -and
        (Test-SpentOnce @{ name = 'ClaudePreheat-Once-20260913-1456'; next = (& $D '2026-09-13 14:56') } $now) -and
        (-not (Test-SpentOnce @{ name = 'ClaudePreheat-Once-20260913-1459'; next = (& $D '2026-09-13 14:59') } $now)) -and
        (-not (Test-SpentOnce @{ name = 'ClaudePreheat-Once-20260913-1638'; next = (& $D '2026-09-13 16:38') } $now)) -and
        (-not (Test-SpentOnce @{ name = 'ClaudePreheat-Wk-0330-MonTue'; next = (& $D '2026-09-13 14:00') } $now)) -and
        (-not (Test-SpentOnce @{ name = 'ClaudePreheat-Wk-0330-MonTue'; next = $null } $now))
    }
    Write-Host '-- preheat: fire integration (stub claude; scheduler, toast and probes doubled) --'
    # Invoke-Fire end to end with every side effect redirected: the journal,
    # state, pit and lock into the temp dir; the scheduler, the toast and the
    # activity/tap probes replaced by doubles defined in the CALLING scope
    # (PowerShell scopes are dynamic, so the callees see them). Nothing here
    # touches the real journal, the real state, a real task, or the account.
    $intStub = Join-Path $Tmp 'fire-int-stub'
    New-Item -ItemType Directory -Path $intStub -Force | Out-Null
    $intOnWin = $true
    try { if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { $intOnWin = $false } } catch { }
    # both stubs refuse an argv that drifted from what preheat.ps1 sends (same
    # contract as the e2e-mac stub): a wrong ping shape must fail, not pass
    if ($intOnWin) {
        $intClaude = Join-Path $intStub 'claude.cmd'
        Set-Content -Path $intClaude -Encoding ASCII -Value @(
            '@echo %* | findstr /C:"--output-format json" >nul || exit /b 2',
            '@echo %* | findstr /C:"--strict-mcp-config" >nul || exit /b 2',
            '@echo %* | findstr /C:"-p " >nul || exit /b 2',
            '@echo {"type":"result","total_cost_usd":0.0001}')
    } else {
        $intClaude = Join-Path $intStub 'claude'
        [System.IO.File]::WriteAllText($intClaude, (@(
            '#!/bin/bash',
            'args=" $* "',
            'for f in " -p " " --model haiku " " --no-session-persistence " " --strict-mcp-config " " --mcp-config " " --output-format json "; do',
            '  case "$args" in *"$f"*) ;; *) echo "stub claude: missing$f in argv: $*" >&2; exit 2 ;; esac',
            'done',
            'echo ''{"type":"result","total_cost_usd":0.0001}''',
            '') -join "`n"))
        & chmod +x $intClaude
        if ($LASTEXITCODE -ne 0) { throw 'chmod on the stub claude failed' }
    }
    # the fire reads mcp-empty.json under $Root; give it a private copy so $Root can move to the temp dir
    Copy-Item (Join-Path $Repo 'mcp-empty.json') (Join-Path $Tmp 'mcp-empty.json') -Force
    function Invoke-FireInt([scriptblock]$LastActivity, [scriptblock]$KnownEnd, [string]$Config, [string]$Seed = '') {
        # one fire against the stub with the given probes -> @{ journal; reg; toast }
        $Root       = $Tmp                                   # .fire-out-*.tmp and friends land here, not in the repo
        $EmptyMcp   = Join-Path $Tmp 'mcp-empty.json'
        $LogPath    = Join-Path $Tmp ('fire-int-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.jsonl')
        if ($Seed) { Set-Content -Path $LogPath -Value $Seed -Encoding UTF8 }
        $StatePath  = Join-Path $Tmp 'fire-int-state.json'
        $FirePit    = Join-Path $Tmp 'fire-int-pit'
        $FireLock   = Join-Path $Tmp 'fire-int.lock'
        $ConfigPath = New-Fixture 'fire-int-sched.json' @($Config)
        (@{ claude = $intClaude } | ConvertTo-Json -Compress) | Set-Content -Path $StatePath -Encoding UTF8
        $script:IntReg = @(); $script:IntToast = ''
        # the self-heal after a failed attempt calls Resolve-ClaudeExe -NoCache, which
        # would otherwise find the REAL claude on PATH and spend real quota: pin it
        function Resolve-ClaudeExe { param([switch]$NoCache) $intClaude }
        # a broken stub must fail in seconds, not sit through 2 x 90s retry sleeps
        function Start-Sleep { param($Seconds, $Milliseconds) }
        function Register-PreheatJob { param([string]$Name, [string[]]$Days, [datetime]$At, [switch]$NoWake) $script:IntReg += @{ name = $Name; at = $At; nowake = [bool]$NoWake } }
        function Remove-StaleOnceJobs { }
        function Send-Toast { param($Ok, $Anchored, $Kind, $Extra) $script:IntToast = ('{0}|{1}|{2}|{3}' -f $Ok, $Anchored, $Kind, $Extra) }
        function Get-Proxy { $null }
        function Get-LastLocalActivity { & $LastActivity }
        function Get-KnownWindowEnd([string]$path = $null) { & $KnownEnd }
        Invoke-Fire 6>$null
        @{ journal = @(Get-JournalEvents $LogPath 50); reg = @($script:IntReg); toast = $script:IntToast }
    }
    Test-Case 'fire integration: a ping inside a running window books ONE no-wake follow-up 2 minutes after the tap reset, journals it, and the toast says so' {
        # the daily rule fires 3h from now (reset = now + 8h), so the follow-up (now + 32min) is not pre-empted
        $sched = '{"rules":[{"days":["Mon","Tue","Wed","Thu","Fri","Sat","Sun"],"reset":"' + (Get-Date).AddHours(8).ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) + '"}]}'
        $end = (Get-Date).AddMinutes(30)
        $r = Invoke-FireInt { (Get-Date).AddHours(-2) } { $end } $sched
        $fire = $r.journal | Where-Object { $_.ev -eq 'fire' } | Select-Object -First 1
        $once = $r.journal | Where-Object { $_.ev -eq 'schedule-once' } | Select-Object -First 1
        $at = $null
        if ($once) { $at = ConvertTo-LocalTime $once.rec.fireAt }
        # to the second: a +60s regression must go red here, not only in the pure unit case
        $fire -and $fire.rec.ok -and ($fire.rec.anchored -eq $false) -and
            $once -and ([string]$once.rec.label -eq 'chase ratelimits') -and $at -and ([Math]::Abs(($at - $end.AddMinutes(2)).TotalSeconds) -lt 30) -and
            ($r.reg.Count -eq 1) -and ($r.reg[0].name -like 'ClaudePreheat-Once-*') -and $r.reg[0].nowake -and
            ($r.toast -eq ('True|False|| - follow-up preheat at ' + $end.AddMinutes(2).ToString('HH:mm')))
    }
    Test-Case 'fire integration: a ping after 5h of quiet anchors a new window and books nothing' {
        $r = Invoke-FireInt { (Get-Date).AddHours(-10) } { $null } '{"rules":[{"days":["Mon"],"reset":"11:07"}]}'
        $fire = $r.journal | Where-Object { $_.ev -eq 'fire' } | Select-Object -First 1
        $fire -and $fire.rec.ok -and ($fire.rec.anchored -eq $true) -and ($r.reg.Count -eq 0) -and
            (@($r.journal | Where-Object { $_.ev -eq 'schedule-once' }).Count -eq 0) -and ($r.toast -like 'True|True|*')
    }
    Test-Case 'fire integration: "chase": false in schedule.json keeps a white ping from booking anything' {
        $r = Invoke-FireInt { (Get-Date).AddHours(-2) } { (Get-Date).AddMinutes(30) } '{"chase":false,"rules":[{"days":["Mon"],"reset":"11:07"}]}'
        $skip = $r.journal | Where-Object { $_.ev -eq 'chase-skip' } | Select-Object -First 1
        ($r.reg.Count -eq 0) -and $skip -and ([string]$skip.rec.reason -like '*disabled*')
    }
    Test-Case 'fire integration: a fire inside a window our own ping opened is white and does NOT chase again' {
        # the temp journal starts with an anchored fire of ours 90 minutes ago
        $seed = '{"ev":"fire","ok":true,"anchored":true,"attempts":1,"ts":"' + (Get-Date).AddMinutes(-90).ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture) + '"}'
        $r = Invoke-FireInt { (Get-Date).AddHours(-10) } { $null } '{"rules":[{"days":["Mon"],"reset":"11:07"}]}' $seed
        $fire = $r.journal | Where-Object { $_.ev -eq 'fire' } | Select-Object -First 1
        $skip = $r.journal | Where-Object { $_.ev -eq 'chase-skip' } | Select-Object -First 1
        # quiet for 10h locally, yet white: the 90-minute-old anchored fire is ours; the chase is skipped for the same reason
        $fire -and ($fire.rec.anchored -eq $false) -and ($r.reg.Count -eq 0) -and $skip -and ([string]$skip.rec.reason -like '*chain*')
    }

    Test-Case 'a white ping wires the chase, and a chase failure can never cost the toast' {
        $src = Get-Content (Join-Path $Repo 'preheat.ps1') -Raw -Encoding UTF8
        ($src -match 'Invoke-Chase \$fireStart \$lastAct \$knownEnd') -and ($src -match "catch \{ Write-Log @\{ ev = 'chase-skip'")
    }

    Test-Case 'status names the time of the local activity that kept the window open' {
        # "landed in existing window" without a time sent the user to the raw jsonl
        (Get-Content (Join-Path $Repo 'preheat.ps1') -Raw -Encoding UTF8) -match 'window was still open'
    }

    Write-Host '-- preheat: fire lock --'
    Test-Case 'a fresh fire lock makes apply/off refuse instead of racing the ping' {
        # apply/off rewrite the very job a running fire lives inside; on macOS
        # bootout SIGTERMs the ping mid-flight
        $FireLock = Join-Path $Tmp 'fire.lock'   # shadows the real lock in this scope
        '{"pid":1,"job":"ClaudePreheat-Once-20260101-0000","startedAt":"2026-01-01T00:00:00"}' |
            Set-Content -Path $FireLock -Encoding UTF8
        $msg = ''
        try { Wait-FireLock -MaxSec 1 } catch { $msg = $_.Exception.Message }
        ($msg -like '*running right now*') -and (Test-Path $FireLock)
    }
    Test-Case 'a fire lock older than 20 minutes is a corpse: deleted, not waited on' {
        $FireLock = Join-Path $Tmp 'fire.lock'
        Set-Content -Path $FireLock -Value '{}' -Encoding UTF8
        (Get-Item $FireLock).LastWriteTime = (Get-Date).AddMinutes(-30)
        Wait-FireLock -MaxSec 1
        -not (Test-Path $FireLock)
    }

    Write-Host '-- preheat: activity detection --'
    Test-Case 'idle-session bookkeeping records do NOT count as activity' {
        # the trap: attachment / away_summary / turn_duration are appended to an
        # open-but-idle session, so "the file grew" is not a turn
        $f = New-Fixture 'idle.jsonl' @(
            (Rec-User 'hello' '2026-07-26T01:00:00.000Z' $null),
            (Rec-Assistant 'hi' '2026-07-26T01:00:05.000Z'),
            (Rec-Bookkeeping 'attachment' '2026-07-26T09:00:00.000Z'),
            (Rec-Bookkeeping 'away_summary' '2026-07-26T09:30:00.000Z'),
            (Rec-Bookkeeping 'turn_duration' '2026-07-26T09:30:01.000Z')
        )
        $act = Get-TranscriptActivity $f
        $expected = ([datetimeoffset]::Parse('2026-07-26T01:00:05.000Z')).LocalDateTime
        $act -eq $expected
    }
    Test-Case 'a bumped file mtime does NOT count as activity' {
        # the trap: local indexers/backups touch the file without appending
        $f = New-Fixture 'touched.jsonl' @(
            (Rec-User 'hello' '2026-07-26T01:00:00.000Z' $null),
            (Rec-Assistant 'hi' '2026-07-26T01:00:05.000Z')
        )
        (Get-Item $f).LastWriteTime = (Get-Date).AddMinutes(1)
        $act = Get-TranscriptActivity $f
        $act -lt (Get-Date).AddHours(-1)
    }
    Test-Case 'newest of several real turns wins' {
        $f = New-Fixture 'many.jsonl' @(
            (Rec-User 'first' '2026-07-26T01:00:00.000Z' $null),
            (Rec-Assistant 'a' '2026-07-26T02:00:00.000Z'),
            (Rec-User 'second' '2026-07-26T03:00:00.000Z' $null),
            (Rec-Assistant 'b' '2026-07-26T04:00:00.000Z')
        )
        (Get-TranscriptActivity $f) -eq ([datetimeoffset]::Parse('2026-07-26T04:00:00.000Z')).LocalDateTime
    }
    Test-Case 'transcript with no real turn yields null' {
        $f = New-Fixture 'meta-only.jsonl' @((Rec-Bookkeeping 'away_summary' '2026-07-26T09:00:00.000Z'))
        $null -eq (Get-TranscriptActivity $f)
    }
    Test-Case 'unreadable path yields null instead of throwing' {
        $null -eq (Get-TranscriptActivity (Join-Path $Tmp 'does-not-exist.jsonl'))
    }

    Write-Host '-- preheat: learn (windows, suggestions, utilization) --'
    Test-Case 'window reconstruction: prompts inside 5h ride one window, later ones anchor anew' {
        $base = (Get-Date).Date.AddDays(-3).AddHours(9)
        $wins = @(Get-WindowStats @($base, $base.AddHours(1), $base.AddHours(4), $base.AddHours(6)))
        ($wins.Count -eq 2) -and ($wins[0].anchor -eq $base) -and
            ($wins[0].last -eq $base.AddHours(4)) -and ($wins[1].anchor -eq $base.AddHours(6))
    }
    Test-Case 'learn report: median start -> reset suggestion, and 7-day utilization' {
        # two windows exactly 7 days apart (same weekday by construction):
        # medians 09:00/09:00 -> suggest 10:00; only the recent one counts for
        # utilization: engaged 1.5h + 0.5h grace of 5h = 40%
        $a1 = (Get-Date).Date.AddDays(-10).AddHours(9)
        $a2 = $a1.AddDays(7)
        $rep = Get-LearnReport @($a1, $a1.AddHours(1), $a2, $a2.AddHours(1.5)) (Get-Date)
        $day = @($rep.days | Where-Object { $_.samples -eq 2 })
        ($day.Count -eq 1) -and ($day[0].suggest -eq '10:00') -and
            ($rep.waste.windows -eq 1) -and ($rep.waste.usedPct -eq 40)
    }
    Test-Case 'a single observed window per weekday yields no suggestion (need >=2)' {
        $a1 = (Get-Date).Date.AddDays(-3).AddHours(9)
        $rep = Get-LearnReport @($a1, $a1.AddHours(1)) (Get-Date)
        ($rep.days.Count -eq 1) -and ($null -eq $rep.days[0].suggest)
    }
    Test-Case 'a start near midnight carries the suggested reset to the NEXT weekday' {
        # regression (review 2026-08-15): median 23:20 + 1h wraps to 00:30 but
        # kept the same weekday, so the rule fired a full day early and the
        # preheated window was ~23h dead before the user sat down
        $a1 = (Get-Date).Date.AddDays(-10).AddHours(23).AddMinutes(20)
        $a2 = $a1.AddDays(7)
        $rep = Get-LearnReport @($a1, $a1.AddMinutes(30), $a2, $a2.AddMinutes(30)) (Get-Date)
        $day = @($rep.days | Where-Object { $_.samples -eq 2 })
        $expectNext = @('Mon','Tue','Wed','Thu','Fri','Sat','Sun')
        $ix = [array]::IndexOf($expectNext, $a1.DayOfWeek.ToString().Substring(0,3))
        ($day.Count -eq 1) -and ($day[0].suggest -eq '00:30') -and
            ($day[0].suggestDay -eq $expectNext[(($ix + 1) % 7)])
    }
    Test-Case 'history parsing: epoch-ms lines in range count, old and junk lines do not' {
        $prev = $env:USERPROFILE
        try {
            $env:USERPROFILE = $Tmp
            $hd = Join-Path $Tmp '.claude'
            New-Item -ItemType Directory -Path $hd -Force | Out-Null
            $ms = { param($d) [DateTimeOffset]::new($d).ToUnixTimeMilliseconds() }
            @(
                ('{"display":"x","timestamp":' + (& $ms (Get-Date).AddDays(-2)) + ',"project":"p"}'),
                ('{"display":"y","timestamp":' + (& $ms (Get-Date).AddDays(-1)) + ',"project":"p"}'),
                ('{"display":"old","timestamp":' + (& $ms (Get-Date).AddDays(-35)) + ',"project":"p"}'),
                'not json at all'
            ) | Set-Content -Path (Join-Path $hd 'history.jsonl') -Encoding UTF8
            $st = Get-HistoryTimestamps 30
            $st.Count -eq 2
        } finally { $env:USERPROFILE = $prev }
    }
    Test-Case 'learn message distinguishes missing history from stale history' {
        $prev = $env:USERPROFILE
        try {
            $env:USERPROFILE = Join-Path $Tmp 'learn-home'
            $hd = Join-Path $env:USERPROFILE '.claude'
            New-Item -ItemType Directory -Path $hd -Force | Out-Null
            $missing = @(Invoke-Learn 6>&1) -join ' '
            $ms = [DateTimeOffset]::new((Get-Date).AddDays(-90)).ToUnixTimeMilliseconds()
            ('{"timestamp":' + $ms + '}') | Set-Content -Path (Join-Path $hd 'history.jsonl') -Encoding UTF8
            $stale = @(Invoke-Learn 6>&1) -join ' '
            ($missing -like '*no prompt history found*') -and
                ($stale -like '*no prompts in the last 30 days*') -and
                ($missing -like ('*' + (Join-Path $hd 'history.jsonl') + '*'))
        } finally { $env:USERPROFILE = $prev }
    }

    Write-Host '-- preheat: journal rotation --'
    Test-Case 'a journal over 2MB is trimmed to the last 1000 lines + the new one' {
        $LogPath = Join-Path $Tmp 'rot.jsonl'   # shadows the real journal in this scope
        $filler = '{"ev":"x","pad":"' + ('y' * 200) + '"}'
        Set-Content -Path $LogPath -Value (@($filler) * 12000 -join "`n") -Encoding UTF8
        $before = (Get-Item $LogPath).Length
        Write-Log @{ ev = 'test' }
        $lines = @(Get-Content $LogPath)
        ($before -gt 2MB) -and ($lines.Count -eq 1001) -and ($lines[-1] -like '*"ev":"test"*')
    }

    Write-Host '-- platform: job names + launchd mapping (pure, runs on any OS) --'
    Test-Case 'launchd label round-trip preserves the job name' {
        (ConvertFrom-LaunchdLabel (ConvertTo-LaunchdLabel 'ClaudePreheat-Wk-0400-MonTueWedThuFri')) -eq 'ClaudePreheat-Wk-0400-MonTueWedThuFri'
    }
    Test-Case 'weekly name -> next run: encoded weekday + time, always in the future' {
        $n = Get-JobNextRun 'ClaudePreheat-Wk-0745-TueWedThu'
        ($n -gt (Get-Date)) -and ($n.Hour -eq 7) -and ($n.Minute -eq 45) -and
            (@('Tuesday', 'Wednesday', 'Thursday') -contains $n.DayOfWeek.ToString())
    }
    Test-Case 'once name -> next run: exact datetime parsed from the name' {
        (Get-JobNextRun 'ClaudePreheat-Once-20261231-1530') -eq ([datetime]::new(2026, 12, 31, 15, 30, 0))
    }
    Test-Case 'unrecognized job name -> null next run' {
        $null -eq (Get-JobNextRun 'SomethingElse')
    }
    Test-Case 'a listed job reports the preheat.ps1 path baked into it' {
        # read-only: a moved or renamed repo leaves jobs that still show a next
        # run while every fire is a silent no-op, so status needs the path back
        $jobs = @(Get-PreheatJobs)
        if ($jobs.Count -eq 0) { Write-Host '    (no preheat jobs registered here - skipped)'; return 'SKIP' }
        $ok = $true
        foreach ($j in $jobs) { if (-not $j.ContainsKey('script')) { $ok = $false } }
        $ok
    }
    Test-Case 'weekly plist: one Weekday dict per day, hour/minute, paths, PATH snapshot' {
        $xml = Build-LaunchdPlist -Name 'ClaudePreheat-Wk-0400-SatSun' -Days @('Saturday', 'Sunday') `
            -At ([datetime]::new(2026, 1, 1, 4, 0, 0)) -HostShell '/usr/local/bin/pwsh' -ScriptPath '/repo/preheat.ps1' -PathEnv '/usr/bin:/bin'
        (([regex]::Matches($xml, '<key>Weekday</key>')).Count -eq 2) -and
            ($xml -like '*<key>Weekday</key><integer>6</integer>*') -and
            ($xml -like '*<key>Weekday</key><integer>0</integer>*') -and
            ($xml -like '*<key>Hour</key><integer>4</integer>*') -and
            ($xml -like '*<string>/usr/local/bin/pwsh</string>*') -and
            ($xml -like '*<string>/repo/preheat.ps1</string>*') -and
            ($xml -like '*<key>PATH</key><string>/usr/bin:/bin</string>*') -and
            ($xml -like '*<key>CLAUDE_PREHEAT_SELF</key><string>ClaudePreheat-Wk-0400-SatSun</string>*') -and
            ($xml -like '*com.claude-preheat.Wk-0400-SatSun*')
    }
    Test-Case 'once plist: pins Month and Day (stale cleanup neutralizes the yearly repeat)' {
        $xml = Build-LaunchdPlist -Name 'ClaudePreheat-Once-20260824-1530' -Days @() `
            -At ([datetime]::new(2026, 8, 24, 15, 30, 0)) -HostShell '/p' -ScriptPath '/s' -PathEnv '/b'
        ($xml -like '*<key>Month</key><integer>8</integer>*') -and
            ($xml -like '*<key>Day</key><integer>24</integer>*') -and
            ($xml -like '*<key>Minute</key><integer>30</integer>*') -and
            ($xml -notlike '*Weekday*')
    }
    Test-Case 'plist XML-escapes ampersands in paths and PATH' {
        $xml = Build-LaunchdPlist -Name 'ClaudePreheat-Once-20260101-0000' -Days @() `
            -At ([datetime]::new(2026, 1, 1, 0, 0, 0)) -HostShell '/a&b/pwsh' -ScriptPath '/s' -PathEnv '/x&y'
        ($xml -like '*/a&amp;b/pwsh*') -and ($xml -like '*/x&amp;y*') -and ($xml -notlike '*<string>/a&b/pwsh</string>*')
    }

    Write-Host '-- platform: host shell resolution (Store pwsh alias) --'
    Test-Case 'a versioned Store pwsh path is only swapped for its alias when the alias is proven to launch' {
        $store = 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe'
        $msi   = 'C:\Program Files\PowerShell\7\pwsh.exe'
        $alias = 'C:\Users\u\AppData\Local\Microsoft\WindowsApps\Microsoft.PowerShell_8wekyb3d8bbwe\pwsh.exe'
        $emptyRoot = Join-Path $Tmp 'no-aliases'
        New-Item -ItemType Directory -Path $emptyRoot -Force | Out-Null
        # no alias present -> the input comes back untouched, never a made-up path;
        # a non-Store path and the alias itself are never touched at all
        ((Resolve-StoreShellAlias $store -AliasRoot $emptyRoot) -eq $store) -and
            ((Resolve-StoreShellAlias $msi -AliasRoot $emptyRoot) -eq $msi) -and
            ((Resolve-StoreShellAlias $alias -AliasRoot $emptyRoot) -eq $alias)
    }
    Test-Case 'the host shell that gets baked into jobs exists, and on a Store pwsh it is the update-proof alias' {
        $r = Resolve-HostShell
        if (-not $r -or -not (Test-Path $r)) { return "resolved to a path that does not exist: $r" }
        $p = Get-Command pwsh -ErrorAction SilentlyContinue
        # MSI / Homebrew / self-contained installs have no versioned Store folder:
        # nothing to swap, the existence check above is the whole assertion.
        # A versioned folder carries the double underscore before the publisher
        # id (..._7.6.6.0_x64__8wekyb3d8bbwe); the alias folder does not.
        if (-not $p -or ($p.Source -notmatch '\\WindowsApps\\Microsoft\.PowerShell_[^\\]*__')) { return $true }
        $r -notmatch '\\WindowsApps\\Microsoft\.PowerShell_[^\\]*__'
    }
}

# ------------------------------------------------------------------ panel.ps1
Write-Host ''
Write-Host '-- panel: HTTP surface (spare port 7879) --'
$panelPort = 7879
$panelProc = $null
try {
    # CI runs this suite twice on Windows; PREHEAT_TEST_SHELL pins which engine
    # hosts the panel so the 5.1 job really exercises the panel under 5.1
    $shell = $env:PREHEAT_TEST_SHELL
    if ($shell -ne 'powershell' -and $shell -ne 'pwsh') {
        $shell = 'pwsh'
        if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) { $shell = 'powershell' }
    }
    $spArgs = @{
        FilePath = $shell; PassThru = $true
        ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Repo 'panel.ps1'),
            '-Port', $panelPort, '-NoBrowser')
    }
    # -WindowStyle exists only on Windows editions of Start-Process
    $onWin = $true
    try { if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { $onWin = $false } } catch { }
    if ($onWin) { $spArgs.WindowStyle = 'Hidden' }
    # the child inherits this: its request log lands in the temp dir, not in the repo
    # (a LIVE panel on 7878 may keep appending to the repo log meanwhile, so the
    # check below looks only at lines added during this run, for the test port)
    $repoPanelLog = Join-Path $Repo 'panel-log.txt'
    $repoPanelLogLines = 0
    if (Test-Path $repoPanelLog) { $repoPanelLogLines = @(Get-Content $repoPanelLog -Encoding UTF8).Count }
    $env:PREHEAT_PANEL_LOG = Join-Path $Tmp 'panel-log.txt'
    $panelProc = Start-Process @spArgs
    Remove-Item Env:PREHEAT_PANEL_LOG -ErrorAction SilentlyContinue
    $base = "http://localhost:$panelPort"
    $up = $false
    for ($i = 0; $i -lt 25 -and -not $up; $i++) {
        Start-Sleep -Milliseconds 700
        try { $null = Invoke-WebRequest -Uri "$base/api/status" -UseBasicParsing -TimeoutSec 5; $up = $true } catch { }
    }

    Test-Case 'panel comes up and answers /api/status' { $up }
    Test-Case 'the test panel logs into the temp dir, not into the repo' {
        $leaked = @()
        if (Test-Path $repoPanelLog) {
            $leaked = @(Get-Content $repoPanelLog -Encoding UTF8 | Select-Object -Skip $repoPanelLogLines | Where-Object { $_ -like ('*' + $panelPort + '*') })
        }
        $tmpLog = Join-Path $Tmp 'panel-log.txt'
        (Test-Path $tmpLog) -and ((Get-Content $tmpLog -Raw -Encoding UTF8) -like ('*' + $panelPort + '*')) -and ($leaked.Count -eq 0)
    }

    Test-Case 'GET / serves the page and forbids caching' {
        # stale cached pages masqueraded as bugs twice, hence the header
        $r = Invoke-WebRequest -Uri "$base/" -UseBasicParsing -TimeoutSec 15
        ($r.StatusCode -eq 200) -and ($r.Content -like '*claude-preheat*') -and
            (($r.Headers['Cache-Control'] -join ',') -like '*no-cache*')
    }
    Test-Case 'GET /api/status shapes {preheat:{tasks}}' {
        $s = (Invoke-WebRequest -Uri "$base/api/status" -UseBasicParsing -TimeoutSec 15).Content | ConvertFrom-Json
        ($null -ne $s.preheat) -and ($s.preheat.PSObject.Properties['tasks'])
    }
    Test-Case 'GET /api/schedule returns the rules, an mtime, and no proxy' {
        # mtime is the optimistic lock the apply button hands back; the proxy
        # never reaches the page, so the page can never round-trip it away
        $s = (Invoke-WebRequest -Uri "$base/api/schedule" -UseBasicParsing -TimeoutSec 15).Content | ConvertFrom-Json
        ($null -ne $s.PSObject.Properties['rules']) -and ($null -ne $s.PSObject.Properties['mtime']) -and
            ($null -eq $s.PSObject.Properties['proxy'])
    }
    Test-Case 'unknown path -> 404' {
        try { $null = Invoke-WebRequest -Uri "$base/nope" -UseBasicParsing -TimeoutSec 15; $false }
        catch { $_.Exception.Response.StatusCode.value__ -eq 404 }
    }

    Test-Case 'GET /api/events shapes {events:[...]} even before the first fire' {
        $s = (Invoke-WebRequest -Uri "$base/api/events" -UseBasicParsing -TimeoutSec 15).Content | ConvertFrom-Json
        $null -ne $s.PSObject.Properties['events']
    }

    function Invoke-PanelPost([string]$path, [string]$body, [hashtable]$headers, [string]$contentType) {
        $args = @{ Uri = "$base$path"; Method = 'POST'; Body = $body; UseBasicParsing = $true; TimeoutSec = 30 }
        if ($contentType) { $args.ContentType = $contentType }
        if ($headers) { $args.Headers = $headers }
        try {
            $r = Invoke-WebRequest @args
            return @{ Code = $r.StatusCode; Body = $r.Content }
        } catch {
            $code = 0
            if ($_.Exception.Response) { $code = $_.Exception.Response.StatusCode.value__ }
            return @{ Code = $code; Body = '' }
        }
    }

    Test-Case 'POST without a JSON content type -> 400' {
        (Invoke-PanelPost '/api/preheat/once' '{}' @{ Origin = "http://localhost:$panelPort" } 'text/plain').Code -eq 400
    }
    Test-Case 'POST from a foreign origin -> 403' {
        (Invoke-PanelPost '/api/preheat/once' '{}' @{ Origin = 'http://evil.example' } 'application/json').Code -eq 403
    }
    Test-Case 'GET /api/ratelimits answers a JSON object' {
        $raw = (Invoke-WebRequest -Uri "$base/api/ratelimits" -UseBasicParsing -TimeoutSec 15).Content
        $raw.TrimStart().StartsWith('{')
    }
    Test-Case 'GET /api/learn answers the rhythm report (in-process, cached)' {
        $s = (Invoke-WebRequest -Uri "$base/api/learn" -UseBasicParsing -TimeoutSec 60).Content | ConvertFrom-Json
        $null -ne $s.PSObject.Properties['days']
    }
    Test-Case 'POST /api/preheat/once rejects a hostile value server-side -> 400' {
        # the once endpoint used to trust the body value all the way into the
        # backend command line; a value like  1h\" -Command off  spliced argv
        # tokens through the old Quote-Arg. Rejection must not depend on the
        # browser-side check.
        $bad = '{"kind":"plus","value":"1h\\\" -Command off"}'
        $r1 = Invoke-PanelPost '/api/preheat/once' $bad @{ Origin = "http://localhost:$panelPort" } 'application/json'
        $r2 = Invoke-PanelPost '/api/preheat/once' '{"kind":"at","value":"9am; rm x"}' @{ Origin = "http://localhost:$panelPort" } 'application/json'
        ($r1.Code -eq 400) -and ($r2.Code -eq 400)
    }
    Test-Case 'POST /api/preheat/once rejects a well-formed but impossible clock time -> 400' {
        # 25:00 matched the HH:mm shape and went straight to the backend
        (Invoke-PanelPost '/api/preheat/once' '{"kind":"at","value":"25:00"}' @{ Origin = "http://localhost:$panelPort" } 'application/json').Code -eq 400
    }
    Test-Case 'an IPv6 loopback origin is not a foreign origin' {
        # a panel opened on http://[::1]:PORT sends that Origin back; the
        # allowlist only knew localhost/127.0.0.1, so every button 403'd
        $r = Invoke-PanelPost '/api/preheat/once' '{}' @{ Origin = "http://[::1]:$panelPort" } 'application/json'
        ($r.Code -ne 403) -and ($r.Code -gt 0)
    }
    Test-Case 'POST /api/preheat/apply rejects an unusable rule set -> 400' {
        $o = @{ Origin = "http://localhost:$panelPort" }
        $empty = Invoke-PanelPost '/api/preheat/apply' '{"rules":[]}' $o 'application/json'
        $noDay = Invoke-PanelPost '/api/preheat/apply' '{"rules":[{"days":[],"reset":"09:00"}]}' $o 'application/json'
        $badHr = Invoke-PanelPost '/api/preheat/apply' '{"rules":[{"days":["Mon"],"reset":"25:00"}]}' $o 'application/json'
        ($empty.Code -eq 400) -and ($noDay.Code -eq 400) -and ($badHr.Code -eq 400)
    }
    Test-Case 'POST /api/preheat/apply refuses a stale baseMtime -> 409' {
        # THE only rule-valid apply this suite may send: the optimistic lock has
        # to stop it BEFORE schedule.json is rewritten and the tasks re-registered.
        # If it ever answers anything else, stop the suite rather than find out
        # what it did to the machine's real schedule.
        $body = '{"rules":[{"days":["Mon"],"reset":"09:00"}],"baseMtime":"1"}'
        $r = Invoke-PanelPost '/api/preheat/apply' $body @{ Origin = "http://localhost:$panelPort" } 'application/json'
        if ($r.Code -ne 409) {
            throw ('apply with a stale baseMtime answered {0}, not 409 - schedule.json and the registered tasks may have been rewritten' -f $r.Code)
        }
        $true
    }
} finally {
    if ($panelProc) { try { Stop-Process -Id $panelProc.Id -Force -ErrorAction SilentlyContinue } catch { } }
}

# -------------------------------------------------- statusline tap (node)
Write-Host ''
Write-Host '-- statusline tap --'
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
# PowerShell pipes re-encode bytes, so stdin/stdout redirection goes through the
# native shell: cmd on Windows, sh elsewhere (the `"a" < "b" > "c"` syntax is shared).
function Invoke-Redirected([string]$Line) {
    $win = $true
    try { if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { $win = $false } } catch { }
    if ($win) { & cmd /c $Line } else { & sh -c $Line }
}
Test-Case 'tap forwards stdin byte-identical and caches rate_limits beside itself' {
    if (-not $nodeCmd) { Write-Host '    (node not on PATH - skipped)'; return 'SKIP' }
    $td = Join-Path $Tmp 'tap'
    New-Item -ItemType Directory -Path $td -Force | Out-Null
    Copy-Item (Join-Path $Repo 'statusline-tap.cjs') $td
    $sample = '{"model":{"display_name":"X"},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1786849200}}}'
    [System.IO.File]::WriteAllText((Join-Path $td 'in.json'), $sample)
    Invoke-Redirected ('"{0}" "{1}" < "{2}" > "{3}"' -f $nodeCmd.Source, (Join-Path $td 'statusline-tap.cjs'), (Join-Path $td 'in.json'), (Join-Path $td 'out.bin'))
    $in  = [System.IO.File]::ReadAllBytes((Join-Path $td 'in.json'))
    $out = [System.IO.File]::ReadAllBytes((Join-Path $td 'out.bin'))
    $state = Join-Path $td 'state-ratelimits.json'
    ($in.Length -eq $out.Length) -and (-not (Compare-Object $in $out)) -and (Test-Path $state) -and
        ((Get-Content $state -Raw -Encoding UTF8 | ConvertFrom-Json).rate_limits.five_hour.used_percentage -eq 12)
}
Test-Case 'tap --solo renders a usage line for users with no statusline of their own' {
    if (-not $nodeCmd) { Write-Host '    (node not on PATH - skipped)'; return 'SKIP' }
    $td = Join-Path $Tmp 'tap'
    $line = Invoke-Redirected ('"{0}" "{1}" --solo < "{2}"' -f $nodeCmd.Source, (Join-Path $td 'statusline-tap.cjs'), (Join-Path $td 'in.json'))
    ($line -join '') -match '5h 12%'
}
Test-Case 'tap survives non-JSON stdin by forwarding it untouched' {
    if (-not $nodeCmd) { Write-Host '    (node not on PATH - skipped)'; return 'SKIP' }
    $td = Join-Path $Tmp 'tap'
    [System.IO.File]::WriteAllText((Join-Path $td 'junk.txt'), 'not json at all')
    Invoke-Redirected ('"{0}" "{1}" < "{2}" > "{3}"' -f $nodeCmd.Source, (Join-Path $td 'statusline-tap.cjs'), (Join-Path $td 'junk.txt'), (Join-Path $td 'junk.out'))
    (Get-Content (Join-Path $td 'junk.out') -Raw) -eq 'not json at all'
}

# ----------------------------------------------------------------- statics
Write-Host ''
Write-Host '-- static hygiene --'
Test-Case 'no shipped file still carries the old name' {
    # this file is excluded: it necessarily spells the old name to test for it.
    # The glob must cover EVERY text file that ships - the rename once survived
    # for weeks inside schedule.example.json because only ps1/md/html were scanned
    $old = [char]0x69 + 'gnite'
    $paths = @((Join-Path $Repo '*.ps1'), (Join-Path $Repo '*.md'), (Join-Path $Repo '*.json'),
        (Join-Path $Repo '*.vbs'), (Join-Path $Repo 'LICENSE'), (Join-Path $Repo 'web\*.html'))
    # test.ps1 must spell the old name to test for it; schedule.json is the
    # user's untracked personal copy (only schedule.example.json ships)
    $skip = @('test.ps1', 'schedule.json')
    $hits = @(Select-String -Path $paths -Pattern $old -ErrorAction SilentlyContinue |
        Where-Object { (Split-Path $_.Path -Leaf) -notin $skip })
    $hits.Count -eq 0
}
Test-Case 'the page uses plain wording (no musical-string metaphor)' {
    # code point instead of the literal CJK char: keeps this file pure ASCII
    (Get-Content (Join-Path $Repo 'web\index.html') -Raw -Encoding UTF8) -notmatch ([string][char]0x5F26)
}
Test-Case 'panel page ships bilingual: string table, language toggle, persisted choice' {
    # every user-facing string must come from the I18N table so the header
    # toggle can swap the whole page; the choice persists in localStorage
    $h = Get-Content (Join-Path $Repo 'web\index.html') -Raw -Encoding UTF8
    ($h -match 'var I18N') -and ($h -match "id=`"btnLang`"") -and
        ($h -match 'clr_lang') -and ($h -match 'data-i18n=') -and
        ($h -match 'function t\(')
}
Test-Case 'panel page ships the fire-history block and its strings in both languages' {
    # the collapsed list under the scheduled preheats: a verdict per fire, in
    # the user's words, in both tables, fed by /api/events
    $h = Get-Content (Join-Path $Repo 'web\index.html') -Raw -Encoding UTF8
    $cut = $h.IndexOf('  en: {')
    if ($cut -lt 0) { return $false }
    $zh = $h.Substring(0, $cut); $en = $h.Substring($cut)
    $ok = ($h -match 'id="evbox"') -and ($h -match '/api/events') -and ($h -match 'id="evDays"') -and ($h -match 'id="evMax"') -and ($h -match 'id="evKind"')
    foreach ($k in @('ev_h:', 'ev_ok:', 'ev_noeff:', 'ev_fail:', 'ev_ok_line:', 'ev_noeff_line:', 'ev_fail_limit:', 'ev_fail_auth:', 'ev_kind_all:')) {
        if (-not $zh.Contains($k) -or -not $en.Contains($k)) { $ok = $false }
    }
    $ok
}
Test-Case 'the scheduled-task registrar keeps WakeToRun for weekly fires (sleep must not eat a fire); only a -NoWake one-shot drops it' {
    $p = Get-Content (Join-Path $Repo 'platform.ps1') -Raw -Encoding UTF8
    $p.Contains('if (-not $NoWake) { $p.WakeToRun = $true }') -and $p.Contains('New-PreheatSettings -NoWake:$NoWake')
}
Test-Case 'the registrar also survives a laptop running on battery' {
    # the Task Scheduler default is "only on AC, stop when unplugged": every
    # fire on an unplugged laptop was silently skipped
    $p = Get-Content (Join-Path $Repo 'platform.ps1') -Raw -Encoding UTF8
    ($p -match '-AllowStartIfOnBatteries') -and ($p -match '-DontStopIfGoingOnBatteries')
}
Test-Case 'apply forces the fire specs into an array before planning' {
    # a one-rule schedule.json unrolls to a bare hashtable whose .Count is its
    # key count, so the plan built from it registered the wrong thing
    (Get-Content (Join-Path $Repo 'preheat.ps1') -Raw -Encoding UTF8) -match '\$specs\s*=\s*@\(Get-FireSpecs'
}
Test-Case 'every clock parse pins InvariantCulture, not the desktop culture' {
    # a bare ParseExact reads 'HH:mm' with the CURRENT culture's time separator
    # and calendar. The runtime happens to accept ':' anyway today, so the
    # culture case above cannot see this slip - only the source can.
    $ok = $true
    foreach ($f in @('preheat.ps1', 'platform.ps1')) {
        $c = Get-Content (Join-Path $Repo $f) -Raw -Encoding UTF8
        $all = ([regex]::Matches($c, 'ParseExact')).Count
        $pinned = ([regex]::Matches($c, 'ParseExact\([^\r\n]*InvariantCulture')).Count
        if (($all -lt 1) -or ($all -ne $pinned)) { $ok = $false }
    }
    $ok
}
Test-Case 'journal appends are serialized by a named mutex' {
    # two providers firing at the same minute rotated the 2MB journal
    # read-modify-write and lost each other's records
    (Get-Content (Join-Path $Repo 'preheat.ps1') -Raw -Encoding UTF8) -match 'claude-preheat-journal'
}
Test-Case 'stale once-labels are swept by name pattern, not by what is on disk' {
    # launchd keeps holding a Once label whose plist is already gone
    (Get-Content (Join-Path $Repo 'platform.ps1') -Raw -Encoding UTF8).Contains('Once-\d{8}-\d{4}')
}
Test-Case 'run-hidden.vbs propagates the exit code of what it launched' {
    # it used to swallow every failure: the scheduled task always looked green
    (Get-Content (Join-Path $Repo 'run-hidden.vbs') -Raw).Contains('WScript.Quit sh.Run(cmd, 0, True)')
}
Test-Case 'run-hidden.vbs fails loudly when the host binary it was given is gone' {
    # a Store pwsh update deleted the versioned folder baked into every task and
    # the shim still exited 0 - two fires and the panel silently lost (2026-09-10)
    $v = Get-Content (Join-Path $Repo 'run-hidden.vbs') -Raw
    $v.Contains('fso.FileExists(WScript.Arguments(0))') -and $v.Contains('WScript.Quit 127')
}
Test-Case 'status flags a job whose baked host shell no longer exists' {
    $p = Get-Content (Join-Path $Repo 'platform.ps1') -Raw -Encoding UTF8
    $s = Get-Content (Join-Path $Repo 'preheat.ps1') -Raw -Encoding UTF8
    ($p -match 'shell = \$shellPath') -and ($s -match 'PowerShell updated\?') -and ($s -match '\$t\.shell')
}
Test-Case 'one platform probe for the whole project, and Linux is refused up front' {
    $p = Get-Content (Join-Path $Repo 'platform.ps1') -Raw -Encoding UTF8
    $i = Get-Content (Join-Path $Repo 'install.ps1') -Raw -Encoding UTF8
    ($p -match '\$OnLinux') -and ($i -notmatch '\$onMac\s*=\s*\$false')
}
Test-Case 'the ratelimit card explains an empty cache and dims a stale one' {
    $h = Get-Content (Join-Path $Repo 'web\index.html') -Raw -Encoding UTF8
    (([regex]::Matches($h, 'rl_hint:')).Count -eq 2) -and
        (([regex]::Matches($h, 'rl_stale:')).Count -eq 2) -and
        (([regex]::Matches($h, 'rl_expired:')).Count -eq 2) -and
        ($h -match '\.rl\.stale')
}
Test-Case 'the tap fsyncs the cache before renaming it into place' {
    # a crash between write and rename left a truncated cache the panel parsed as empty
    (Get-Content (Join-Path $Repo 'statusline-tap.cjs') -Raw) -match 'fsyncSync'
}
Test-Case 'the panel computes the rhythm report in-process, not by shelling out' {
    # both directions: the in-process call must exist AND the learn shell-out
    # must not come back (it blocked the single-threaded listener for seconds)
    $pan = Get-Content (Join-Path $Repo 'panel.ps1') -Raw -Encoding UTF8
    ($pan -match 'Get-LearnReport') -and ($pan -notmatch "CmdArgs\s+@\('learn'")
}
Test-Case 'Quote-Arg doubles backslash runs before quotes (argv-splice guard)' {
    # Windows argv parsing treats  \"  as an escaped quote: quoting that only
    # escapes the quote itself lets a trailing-backslash value break out of its
    # argument. The panel's quoter must double backslash runs before any quote
    # and before the closing quote.
    $p = Get-Content (Join-Path $Repo 'panel.ps1') -Raw -Encoding UTF8
    $p.Contains('(\\*)"') -and $p.Contains('(\\+)$')
}
Test-Case 'week-grid chips edit in place via the clock picker, committed on blur/Enter' {
    # changing e.g. 10:00 to 10:30 must not require add-new + delete-old.
    # And the editor must NOT commit on `change` - Chromium fires it per
    # keystroke on time inputs, which ejects the user after one digit
    $html = Get-Content (Join-Path $Repo 'web\index.html') -Raw -Encoding UTF8
    ($html -match 'data-edit=') -and ($html -match 'showPicker') -and
        ($html -notmatch 'tedit') -and
        ($html -notmatch "inp\.addEventListener\('change'")
}
Test-Case 'the panel scrubs the child-session marker before spawning' {
    # a claude that inherits CLAUDE_CODE_CHILD_SESSION silently stops saving
    # transcripts - quota burns, the record never lands (observed live 07-31);
    # the pings preheat.ps1 spawns under the panel must start from a clean env
    (Get-Content (Join-Path $Repo 'panel.ps1') -Raw) -match 'Remove-Item Env:CLAUDE_CODE_CHILD_SESSION'
}
Test-Case 'every shipped script carries a UTF-8 BOM (5.1 decodes BOM-less as ANSI)' {
    # without the BOM, Windows PowerShell 5.1 reads these files through the
    # legacy codepage: on cp936 the middle-dot chars in comments/corpus turn
    # to mojibake, and a bare [] class once became an invalid regex
    $ok = $true
    foreach ($f in @('preheat.ps1', 'panel.ps1', 'platform.ps1', 'install.ps1', 'test.ps1')) {
        $b = [System.IO.File]::ReadAllBytes((Join-Path $Repo $f))
        if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { $ok = $false }
    }
    $ok
}
Test-Case 'every ExitCode-reading Start-Process touches .Handle first (PS 5.1 null trap)' {
    # 5.1 returns a process object whose ExitCode stays null forever unless
    # .Handle was read before the process exits - every ping/backend spawn
    # whose ExitCode we judge must carry the touch
    $ok = $true
    foreach ($f in @('preheat.ps1', 'panel.ps1')) {
        $c = Get-Content (Join-Path $Repo $f) -Raw -Encoding UTF8
        if (([regex]::Matches($c, '\$null = \$p\.Handle')).Count -lt 1) { $ok = $false }
    }
    $ok
}
Test-Case 'statusline on/off consult BOTH settings files and the sidecar path' {
    # regression (review 2026-08-15): off re-derived "the file with a
    # statusLine, local first" and went no-op when the tap sat in the other
    # file; on could then double-wrap and clobber the sidecar
    $r = Get-Content (Join-Path $Repo 'preheat.ps1') -Raw -Encoding UTF8
    ($r -match '\$candFiles') -and ($r -match '\$tapFile') -and
        ($r -match 'sc\.file') -and ($r -match 'already installed \(in')
}
Test-Case 'every script parses' {
    $ok = $true
    foreach ($f in @('preheat.ps1', 'panel.ps1', 'platform.ps1', 'install.ps1', 'test.ps1')) {
        try { $null = [scriptblock]::Create((Get-Content (Join-Path $Repo $f) -Raw)) } catch { $ok = $false }
    }
    $ok
}
Test-Case 'no PowerShell 7-only syntax (project claims 5.1 support)' {
    $ok = $true
    foreach ($f in @('preheat.ps1', 'panel.ps1', 'platform.ps1', 'install.ps1')) {
        $c = Get-Content (Join-Path $Repo $f) -Raw
        if ($c -match '\?\?' -or $c -match '\)\s*\?\s*[^\s]+\s*:\s') { $ok = $false }
    }
    $ok
}
Test-Case 'learn ships end to end: preheat command, panel endpoint, bilingual line' {
    $pre = Get-Content (Join-Path $Repo 'preheat.ps1') -Raw -Encoding UTF8
    $pan = Get-Content (Join-Path $Repo 'panel.ps1') -Raw -Encoding UTF8
    $h = Get-Content (Join-Path $Repo 'web\index.html') -Raw -Encoding UTF8
    ($pre -match "'\^learn\$'") -and ($pan -match '/api/learn') -and
        (([regex]::Matches($h, 'learn_waste:')).Count -eq 2)
}
Test-Case 'the panel surfaces the ratelimit cache bilingually' {
    $p = Get-Content (Join-Path $Repo 'panel.ps1') -Raw -Encoding UTF8
    $h = Get-Content (Join-Path $Repo 'web\index.html') -Raw -Encoding UTF8
    ($p -match '/api/ratelimits') -and ($h -match 'api/ratelimits') -and
        (([regex]::Matches($h, 'rl_5h:')).Count -eq 2)
}
Test-Case 'personal state stays out of git' {
    $ignored = @('schedule.json', 'preheat-log.jsonl', '.claude',
        'state-ratelimits.json', 'statusline-original.json',
        'launchd-err.log', 'claude-ignite-promo', '.fire.lock')
    $ok = $true
    foreach ($p in $ignored) {
        git -C $Repo check-ignore $p 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { $ok = $false }
    }
    $ok
}

# ----------------------------------------------------------------- summary
Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -eq 0) {
    $line = 'ALL PASS  {0}/{0}' -f $script:Pass
    if ($script:Skip -gt 0) { $line += (' ({0} skipped)' -f $script:Skip) }
    Write-Host $line -ForegroundColor Green
    foreach ($s in $script:Skipped) { Write-Host ('  ~ skipped: ' + $s) -ForegroundColor DarkYellow }
    exit 0
}
Write-Host ('{0} passed, {1} FAILED, {2} skipped' -f $script:Pass, $script:Fail, $script:Skip) -ForegroundColor Red
foreach ($f in $script:Failures) { Write-Host ('  - ' + $f) -ForegroundColor Red }
foreach ($s in $script:Skipped) { Write-Host ('  ~ skipped: ' + $s) -ForegroundColor DarkYellow }
exit 1
