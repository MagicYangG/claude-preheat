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

# ---------------------------------------------------------------- stub codex
# one script plays both halves of the real binary (.github/workflows/
# stub-codex.ps1, shared with the macOS e2e): `app-server --stdio` and
# `exec --json`, driven by a config file. The product is pinned to it through
# PREHEAT_CODEX_EXE for this whole run - in-process cases, the panel child and
# the CLI children all inherit it - so no case can reach a real codex (a dev
# box has one signed in; CI has none at all).
$cxDir = Join-Path $Tmp 'codex-stub'
New-Item -ItemType Directory -Path $cxDir -Force | Out-Null
Copy-Item (Join-Path $Repo (Join-Path '.github' (Join-Path 'workflows' 'stub-codex.ps1'))) $cxDir -Force
$cxConfig = Join-Path $cxDir 'stub-config.json'
$cxCalls  = Join-Path $cxDir 'calls.txt'
$cxState  = Join-Path $cxDir 'state.json'
# the engine running this suite hosts the stub too: the 5.1 job stubs with 5.1
$cxShell  = (Get-Process -Id $PID).Path
$cxOnWin  = $true
try { if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { $cxOnWin = $false } } catch { }
if ($cxOnWin) {
    $cxStub = Join-Path $cxDir 'codex.cmd'
    Set-Content -Path $cxStub -Encoding ASCII -Value @(
        ('@if not defined STUB_CODEX_SHELL set "STUB_CODEX_SHELL=' + $cxShell + '"'),
        '@"%STUB_CODEX_SHELL%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0stub-codex.ps1" %*',
        '@exit /b %ERRORLEVEL%')
} else {
    $cxStub = Join-Path $cxDir 'codex'
    [System.IO.File]::WriteAllText($cxStub, (@(
        '#!/bin/bash',
        ('exec "' + $cxShell + '" -NoProfile -NonInteractive -File "$(dirname "$0")/stub-codex.ps1" "$@"'),
        '') -join "`n"))
    & chmod +x $cxStub
    if ($LASTEXITCODE -ne 0) { throw 'chmod on the stub codex failed' }
}
# a missing stub must abort the run: a missing PREHEAT_CODEX_EXE target makes
# Resolve-CodexExe fall through to the real candidates
if (-not ((Test-Path -LiteralPath $cxStub -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $cxDir 'stub-codex.ps1') -PathType Leaf))) {
    throw "stub codex was not set up in $cxDir"
}
$cxEnvPrev = @{}
foreach ($n in @('PREHEAT_CODEX_EXE', 'STUB_CODEX_CONFIG', 'STUB_CODEX_SHELL', 'PREHEAT_CODEX_FORCE_PING')) {
    $cxEnvPrev[$n] = [Environment]::GetEnvironmentVariable($n)
}
$env:PREHEAT_CODEX_EXE = $cxStub
$env:STUB_CODEX_CONFIG = $cxConfig
$env:STUB_CODEX_SHELL  = $cxShell
Remove-Item Env:PREHEAT_CODEX_FORCE_PING -ErrorAction SilentlyContinue

function Set-CodexStub([hashtable]$Over = @{}) {
    # fresh stub state for one case: config rewritten, calls log and the
    # anchored-window state cleared
    $c = [ordered]@{ profile = 'plus5h'; r5 = $null; anchor = $false; exec = 'ok'; rpc = 'ok'; callsLog = $cxCalls; state = $cxState }
    foreach ($k in $Over.Keys) { $c[$k] = $Over[$k] }
    Remove-Item $cxCalls, $cxState -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllText($cxConfig, (ConvertTo-Json -InputObject $c -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
}
function Get-CodexStubCalls {
    if (Test-Path $cxCalls) { return @(Get-Content $cxCalls -Encoding UTF8) }
    @()
}
function Get-CodexStubExecCount { @(Get-CodexStubCalls | Where-Object { $_ -like 'exec stdin=*' }).Count }
function Test-CodexAllowList {
    # every JSON-RPC method that reached the stub is one of the four read-only ones
    $ok = @('initialize', 'initialized', 'account/read', 'account/rateLimits/read')
    foreach ($l in @(Get-CodexStubCalls | Where-Object { $_ -like 'rpc *' })) {
        if ($ok -notcontains ($l.Split(' ')[1])) { return $false }
    }
    $true
}
function Wait-StubPidsGone([int]$Sec = 8) {
    # -> number of stub processes still alive after up to $Sec seconds
    $ids = @(Get-CodexStubCalls | ForEach-Object { if ($_ -match '^start pid=(\d+)') { [int]$Matches[1] } })
    $alive = $ids.Count
    for ($i = 0; $i -lt ($Sec * 4); $i++) {
        $alive = @($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count
        if ($alive -eq 0) { break }
        Start-Sleep -Milliseconds 250
    }
    $alive
}
function Get-CxEnvSnapshot {
    # Use-CodexEnvironment writes these into THIS process: every case that can
    # reach it puts them back afterwards
    $s = @{}
    foreach ($n in @('HTTPS_PROXY', 'HTTP_PROXY', 'CODEX_HOME', 'CLAUDE_PREHEAT_SELF', 'PREHEAT_CODEX_FORCE_PING')) { $s[$n] = [Environment]::GetEnvironmentVariable($n) }
    $s
}
function Restore-CxEnvSnapshot($s) {
    foreach ($n in $s.Keys) {
        if ($null -eq $s[$n]) { Remove-Item ('Env:' + $n) -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($n, $s[$n]) }
    }
}
function Clear-TestProxy {
    # the panel cases talk to a local test panel directly. A proxy left in this
    # process (a Codex case points it at the dead 127.0.0.1:9) would carry even
    # localhost on macOS - .NET bypasses loopback for an env proxy on Windows
    # only - and .NET keeps the default proxy it built first, so reset that too
    foreach ($n in @('HTTPS_PROXY', 'HTTP_PROXY', 'https_proxy', 'http_proxy', 'ALL_PROXY', 'all_proxy')) {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v) {
            # name the value only when it is the suite's own dead proxy (a real one may carry credentials)
            $shown = $(if ($v -eq 'http://127.0.0.1:9') { $v } else { 'from the environment' })
            Write-Host ('  note: {0} was set ({1}); cleared for the panel cases' -f $n, $shown)
            Remove-Item ('Env:' + $n) -ErrorAction SilentlyContinue
        }
    }
    try { if ($PSVersionTable.PSEdition -eq 'Core') { [System.Net.Http.HttpClient]::DefaultProxy = [System.Net.WebProxy]::new() } } catch { }
}
function Read-JsonLines([string]$Path) {
    # every parseable record, oldest first
    $out = @()
    if (Test-Path $Path) {
        foreach ($l in @(Get-Content $Path -Encoding UTF8)) { try { $o = $l | ConvertFrom-Json; if ($o) { $out += $o } } catch { } }
    }
    $out
}
function Test-Prop($o, [string]$Name) { [bool]($o -and $o.PSObject.Properties[$Name]) }
$cxInv = [System.Globalization.CultureInfo]::InvariantCulture

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
    Write-Host '-- preheat: ping stream + rate limits (pure, costs nothing) --'
    $streamOk = @(
        '{"type":"system","subtype":"hook_started","hook_name":"SessionStart:startup"}',
        '{"type":"system","subtype":"hook_response","hook_name":"SessionStart:startup","output":"text a hook printed"}',
        '{"type":"system","subtype":"init","model":"claude-haiku"}',
        '{"type":"assistant","message":{"model":"claude-haiku","content":[{"type":"text","text":"ok"}]}}',
        '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1790010000,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":0.32,"resetsAt":1790010000},"seven_day":{"utilization":0.53,"resetsAt":1790300000}}}}',
        '{"type":"system","subtype":"post_turn_summary"}',
        '{"type":"result","subtype":"success","is_error":false,"result":"ok","total_cost_usd":0.0037}'
    ) -join "`n"
    Test-Case 'Split-PingStream: the result line goes to the verdict, the rate_limit_event comes out alongside' {
        $s = Split-PingStream $streamOk
        $v = Test-PingOutput 0 $s.result ''
        $v.ok -and ([math]::Abs([double]$v.cost - 0.0037) -lt 0.000001) -and $s.rl -and
            ([double]$s.rl.unifiedWindows.five_hour.utilization -eq 0.32) -and ([long]$s.rl.unifiedWindows.five_hour.resetsAt -eq 1790010000)
    }
    Test-Case 'Split-PingStream: a failed run inside the stream still surfaces its reason' {
        $bad = @(
            '{"type":"system","subtype":"init"}',
            '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1790010000,"rateLimitType":"five_hour"}}',
            '{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached|1790010000"}'
        ) -join "`r`n"
        $s = Split-PingStream $bad
        $v = Test-PingOutput 1 $s.result ''
        (-not $v.ok) -and ($v.kind -eq 'limit') -and ($v.err -like 'Claude AI usage limit reached*') -and ($s.rl.status -eq 'rejected')
    }
    Test-Case 'Split-PingStream: the old single-object output and plain text pass through untouched; a stream with no result is empty' {
        $legacy = Split-PingStream '{"type":"result","total_cost_usd":0.0123,"is_error":false}'
        $plain  = Split-PingStream 'hello from claude'
        $cut    = Split-PingStream ('{"type":"system","subtype":"init"}' + "`n" + '{"type":"system","subtype":"hook_response","output":"private hook text"}')
        $none   = Split-PingStream ''
        (Test-PingOutput 0 $legacy.result '').ok -and ($null -eq $legacy.rl) -and
            ($plain.result -eq 'hello from claude') -and
            ($cut.result -eq '') -and (-not (Test-PingOutput 0 $cut.result '').ok) -and
            ($none.result -eq '') -and ($null -eq $none.rl)
    }
    Test-Case 'Read-PingFile: a UTF-8 stream with a Chinese reply survives the file round trip and stays a success' {
        # Windows PowerShell 5.1 reads a BOM-less file in the ANSI code page; on a
        # Chinese desktop (936) a GBK lead byte swallows the quote after the reply
        # and a good ping was judged a failure - then pinged twice more
        $cjk = -join ([char[]]@(0x4F60, 0x597D, 0xFF01, 0x6709, 0x4EC0, 0x4E48, 0x6211, 0x53EF, 0x4EE5, 0x5E2E, 0x4F60, 0x7684, 0x5417, 0xFF1F))
        $text = @(
            '{"type":"system","subtype":"init"}',
            ('{"type":"assistant","message":{"content":[{"type":"text","text":"' + $cjk + '"}]}}'),
            '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.1,"resetsAt":1790010000}}}}',
            ('{"type":"result","subtype":"success","is_error":false,"result":"' + $cjk + '","total_cost_usd":0.0037}')
        ) -join "`n"
        $f = Join-Path $Tmp 'cjk-stream.out'
        [System.IO.File]::WriteAllText($f, $text, (New-Object System.Text.UTF8Encoding($false)))
        $v = Test-PingOutput 0 (Split-PingStream (Read-PingFile $f)).result ''
        $v.ok -and ([math]::Abs([double]$v.cost - 0.0037) -lt 0.000001) -and ((Read-PingFile (Join-Path $Tmp 'no-such.out')) -eq '')
    }
    Test-Case 'Split-PingStream: a stream that dies on a login error still hands the reason over (auth: no retries), never the hook text' {
        $plain = Split-PingStream (@('{"type":"system","subtype":"hook_response","output":"private hook text"}', 'Invalid API key - Please run /login') -join "`n")
        $json  = Split-PingStream (@('{"type":"system","subtype":"init"}', '{"type":"error","error":{"type":"authentication_error","message":"OAuth token has expired"}}') -join "`n")
        $a = Test-PingOutput 1 $plain.result ''
        $b = Test-PingOutput 1 $json.result ''
        ($a.kind -eq 'auth') -and ($a.err -notlike '*private hook text*') -and ($b.kind -eq 'auth')
    }
    Test-Case 'ConvertFrom-RateLimitInfo: both windows in the tap shape, fractions turned into percent' {
        $w = ConvertFrom-RateLimitInfo (Split-PingStream $streamOk).rl
        ($w.five_hour.used_percentage -eq 32) -and ([long]$w.five_hour.resets_at -eq 1790010000) -and
            ($w.seven_day.used_percentage -eq 53) -and ([long]$w.seven_day.resets_at -eq 1790300000)
    }
    Test-Case 'ConvertFrom-RateLimitInfo: no unified windows -> the top-level 5h reset only; a weekly-only event or nothing -> null' {
        $five = ConvertFrom-RateLimitInfo ('{"status":"allowed","resetsAt":1790010000,"rateLimitType":"five_hour"}' | ConvertFrom-Json)
        $week = ConvertFrom-RateLimitInfo ('{"status":"allowed","resetsAt":1790300000,"rateLimitType":"seven_day"}' | ConvertFrom-Json)
        ([long]$five.five_hour.resets_at -eq 1790010000) -and ($null -eq $five.seven_day) -and
            ($null -eq $week) -and ($null -eq (ConvertFrom-RateLimitInfo $null))
    }
    Test-Case 'ConvertFrom-RateLimitInfo: past 100% (overage) stays a percent, a junk utilization keeps its reset' {
        $w = ConvertFrom-RateLimitInfo ('{"unifiedWindows":{"five_hour":{"utilization":1.6,"resetsAt":1790010000},"seven_day":{"utilization":"x","resetsAt":1790300000}}}' | ConvertFrom-Json)
        ($w.five_hour.used_percentage -eq 160) -and ($null -eq $w.seven_day.used_percentage) -and ([long]$w.seven_day.resets_at -eq 1790300000)
    }
    Test-Case 'ground-truth anchor: a window ending ~5h out was opened by the ping; sooner means it rode one; no end -> unknown' {
        $D2 = { param($s) [datetime]::ParseExact($s, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) }
        $fire = & $D2 '2026-09-13 04:10:13'
        (Test-AnchorFromWindow $fire (& $D2 '2026-09-13 09:10:00')) -and
            (Test-AnchorFromWindow (& $D2 '2026-09-13 18:01:07') (& $D2 '2026-09-13 23:00:00')) -and
            (Test-AnchorFromWindow $fire (& $D2 '2026-09-13 08:55:13')) -and
            (-not (Test-AnchorFromWindow $fire (& $D2 '2026-09-13 08:54:13'))) -and
            (-not (Test-AnchorFromWindow $fire (& $D2 '2026-09-13 05:47:00'))) -and
            ($null -eq (Test-AnchorFromWindow $fire (& $D2 '2026-09-13 03:40:00'))) -and
            ($null -eq (Test-AnchorFromWindow $fire $null))
    }
    Test-Case 'Write-RateLimitCache: the fire leaves a tap-shaped cache that Get-KnownWindowEnd reads, and overwrites an older one' {
        $f = Join-Path $Tmp 'rl-fire.json'
        '{"capturedAt":"old","rate_limits":{"five_hour":{"used_percentage":1,"resets_at":1700000000}}}' | Set-Content -Path $f -Encoding UTF8
        Write-RateLimitCache (ConvertFrom-RateLimitInfo (Split-PingStream $streamOk).rl) $f
        $o = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
        $end = Get-KnownWindowEnd $f
        ($o.source -eq 'fire') -and ($o.rate_limits.five_hour.used_percentage -eq 32) -and ($o.rate_limits.seven_day.used_percentage -eq 53) -and
            ($end -eq [DateTimeOffset]::FromUnixTimeSeconds(1790010000).LocalDateTime) -and
            ((Get-Content $f -Raw -Encoding UTF8) -match '"capturedAt":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z"') -and
            (@(Get-ChildItem $Tmp -Filter 'rl-fire.json.tmp*').Count -eq 0)
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
        $fire = & $D '2026-09-13 15:00'; $last = & $D '2026-09-13 13:49'; $wk = & $D '2026-09-14 00:15'
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
        # boundary: the estimate chase at 18:51 holds its own window until 23:51 - a weekly fire before that wins
        $d1 = Get-ChasePlan -FireStart $fire -LastAct $last -KnownEnd $null -NextWeekly (& $D '2026-09-13 23:50') -RecentAnchor $false -Now $fire
        $d2 = Get-ChasePlan -FireStart $fire -LastAct $last -KnownEnd $null -NextWeekly (& $D '2026-09-13 23:52') -RecentAnchor $false -Now $fire
        ($a.skip -like '*chain*') -and ($b.skip -like '*no local*') -and ($c.skip -like '*comes first*') -and
        ($d1.skip -like '*comes first*') -and ($d2.at -eq (& $D '2026-09-13 18:51'))
    }
    Test-Case 'chase plan: no chase when its own 5h window would swallow the next weekly fire (the schedule comes first)' {
        # weekly fires 5.5h apart: a chase at 14:02 would hold the account until
        # ~19:02, so the 17:45 fire lands inside it, misses its own reset, and the
        # no-chains rule then forbids that fire to chase in turn
        $fire = & $D '2026-09-13 12:15'
        $p = Get-ChasePlan -FireStart $fire -LastAct $null -KnownEnd (& $D '2026-09-13 14:00') -NextWeekly (& $D '2026-09-13 17:45') -RecentAnchor $false -Now $fire
        $q = Get-ChasePlan -FireStart $fire -LastAct $null -KnownEnd (& $D '2026-09-13 14:00') -NextWeekly (& $D '2026-09-13 19:05') -RecentAnchor $false -Now $fire
        ($p.skip -like '*comes first*') -and ($q.at -eq (& $D '2026-09-13 14:02'))
    }
    Test-Case 'chase once: a fire knows it IS a follow-up from the journal record of its own one-shot, by name' {
        $j = Join-Path $Tmp 'chase-self.jsonl'
        @(
            '{"ev":"schedule-once","fireAt":"2026-09-13T16:39:00","label":"chase ratelimits","ts":"2026-09-13T12:15:05-07:00"}',
            '{"ev":"schedule-once","fireAt":"2026-09-13T18:00:00","label":"reset 23:00","ts":"2026-09-13T12:20:00-07:00"}'
        ) | Set-Content -Path $j -Encoding UTF8
        (Test-ChaseFire 'ClaudePreheat-Once-20260913-1639' $j) -and
            (-not (Test-ChaseFire 'ClaudePreheat-Once-20260913-1800' $j)) -and
            (-not (Test-ChaseFire 'ClaudePreheat-Wk-0400-MonTue' $j)) -and
            (-not (Test-ChaseFire '' $j)) -and
            (-not (Test-ChaseFire 'ClaudePreheat-Once-20260913-1639' (Join-Path $Tmp 'no-such.jsonl')))
    }
    Test-Case 'chase plan: a follow-up never books another follow-up (once per gap)' {
        $fire = & $D '2026-09-13 15:00'
        $p = Get-ChasePlan -FireStart $fire -LastAct $null -KnownEnd (& $D '2026-09-13 16:37') -NextWeekly $null -RecentAnchor $false -Now $fire -IsChase $true
        $p.skip -like '*follow-up*'
    }
    Test-Case 'chase plan: a known end still chases when nothing local ran (phone or web made the window)' {
        $fire = & $D '2026-09-13 15:00'
        $p = Get-ChasePlan -FireStart $fire -LastAct $null -KnownEnd (& $D '2026-09-13 16:37') -NextWeekly $null -RecentAnchor $false -Now $fire
        ($p.source -eq 'ratelimits') -and ($p.at -eq (& $D '2026-09-13 16:39'))
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
    Test-Case 'Get-FireEvents carries the real reset time a fire learned from its own ping' {
        $j = Join-Path $Tmp 'events-resets.jsonl'
        '{"ev":"fire","ok":true,"anchored":true,"anchor_src":"ratelimit","resets_at":"2026-09-12 09:00","attempts":1,"ts":"2026-09-12T04:00:12-07:00"}' | Set-Content -Path $j -Encoding UTF8
        $ev = @(Get-FireEvents $j 60)
        ($ev.Count -eq 1) -and ($ev[0].resets_at -eq '2026-09-12 09:00')
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
            '@echo %* | findstr /C:"--output-format stream-json" >nul || exit /b 2',
            '@echo %* | findstr /C:"--verbose" >nul || exit /b 2',
            '@echo %* | findstr /C:"--strict-mcp-config" >nul || exit /b 2',
            '@echo %* | findstr /C:"-p " >nul || exit /b 2',
            '@echo {"type":"system","subtype":"init"}',
            '@if defined STUB_RL echo %STUB_RL%',
            '@if defined STUB_RESULT echo %STUB_RESULT%',
            '@if defined STUB_RESULT exit /b 1',
            '@echo {"type":"result","total_cost_usd":0.0001}')
    } else {
        $intClaude = Join-Path $intStub 'claude'
        [System.IO.File]::WriteAllText($intClaude, (@(
            '#!/bin/bash',
            'args=" $* "',
            'for f in " -p " " --model haiku " " --no-session-persistence " " --strict-mcp-config " " --mcp-config " " --output-format stream-json " " --verbose "; do',
            '  case "$args" in *"$f"*) ;; *) echo "stub claude: missing$f in argv: $*" >&2; exit 2 ;; esac',
            'done',
            'echo ''{"type":"system","subtype":"init"}''',
            '[ -n "$STUB_RL" ] && echo "$STUB_RL"',
            'if [ -n "$STUB_RESULT" ]; then echo "$STUB_RESULT"; exit 1; fi',
            'echo ''{"type":"result","total_cost_usd":0.0001}''',
            '') -join "`n"))
        & chmod +x $intClaude
        if ($LASTEXITCODE -ne 0) { throw 'chmod on the stub claude failed' }
    }
    # the fire reads mcp-empty.json under $Root; give it a private copy so $Root can move to the temp dir
    Copy-Item (Join-Path $Repo 'mcp-empty.json') (Join-Path $Tmp 'mcp-empty.json') -Force
    function Invoke-FireInt([scriptblock]$LastActivity, [scriptblock]$KnownEnd, [string]$Config, [string]$Seed = '', [string]$Rl = '', [string]$Result = '', [string]$Self = '') {
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
        function Register-PreheatJob { param([string]$Name, [string[]]$Days, [datetime]$At, [switch]$NoWake, [string[]]$ScriptArgs) $script:IntReg += @{ name = $Name; at = $At; nowake = [bool]$NoWake; args = @($ScriptArgs) } }
        function Remove-StaleOnceJobs { }
        function Send-Toast { param($Ok, $Anchored, $Kind, $Extra, [string]$Provider, [string]$Text) $script:IntToast = ('{0}|{1}|{2}|{3}' -f $Ok, $Anchored, $Kind, $Extra) }
        function Get-Proxy { $null }
        function Get-LastLocalActivity { & $LastActivity }
        function Get-KnownWindowEnd([string]$path = $null) { & $KnownEnd }
        # the stub echoes this rate_limit_event line (inherited env); none = the pre-stream path
        # the job name a scheduled fire runs under (a one-shot chase, a weekly job...)
        $env:STUB_RL = $Rl; $env:STUB_RESULT = $Result; $env:CLAUDE_PREHEAT_SELF = $Self
        try { Invoke-Fire 6>$null } finally { Remove-Item Env:STUB_RL, Env:STUB_RESULT, Env:CLAUDE_PREHEAT_SELF -ErrorAction SilentlyContinue }
        @{ journal = @(Get-JournalEvents $LogPath 50); reg = @($script:IntReg); toast = $script:IntToast }
    }
    Test-Case 'fire integration: a ping inside a running window books ONE no-wake follow-up 2 minutes after the tap reset, journals it, and the toast says so' {
        # the daily rule fires 6h from now (reset = now + 11h): beyond the follow-up's own window (now + 32min + 5h)
        $sched = '{"rules":[{"days":["Mon","Tue","Wed","Thu","Fri","Sat","Sun"],"reset":"' + (Get-Date).AddHours(11).ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) + '"}]}'
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
            (($r.reg[0].args -join ' ') -eq ('fire -Job ' + $r.reg[0].name)) -and
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

    function New-StubRl([datetime]$End) {
        # one rate_limit_event line whose 5h window ends at $End (epoch seconds)
        $e5 = (New-Object DateTimeOffset $End).ToUnixTimeSeconds()
        $e7 = (New-Object DateTimeOffset ($End.AddDays(3))).ToUnixTimeSeconds()
        '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":' + $e5 + ',"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":0.32,"resetsAt":' + $e5 + '},"seven_day":{"utilization":0.53,"resetsAt":' + $e7 + '}}}}'
    }
    Test-Case 'fire integration: the ping''s own rate limits say it rode a window - chase at the REAL end even with no local activity and a stale tap, cache refreshed' {
        $sched = '{"rules":[{"days":["Mon","Tue","Wed","Thu","Fri","Sat","Sun"],"reset":"' + (Get-Date).AddHours(11).ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) + '"}]}'
        $end = (Get-Date).AddMinutes(30)
        $end = $end.AddSeconds(-$end.Second).AddMilliseconds(-$end.Millisecond)
        Remove-Item (Join-Path $Tmp 'state-ratelimits.json') -ErrorAction SilentlyContinue
        # the tap still holds a window that ended an hour ago (desktop-only use): the measured end must win
        $r = Invoke-FireInt { $null } { (Get-Date).AddHours(-1) } $sched '' (New-StubRl $end)
        $fire = $r.journal | Where-Object { $_.ev -eq 'fire' } | Select-Object -First 1
        $once = $r.journal | Where-Object { $_.ev -eq 'schedule-once' } | Select-Object -First 1
        $at = $null
        if ($once) { $at = ConvertTo-LocalTime $once.rec.fireAt }
        $cache = $null
        try { $cache = Get-Content (Join-Path $Tmp 'state-ratelimits.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        # cost 0.0001 only comes through when the verdict read the RESULT line, not the whole stream
        $fire -and $fire.rec.ok -and ($fire.rec.anchored -eq $false) -and ([string]$fire.rec.anchor_src -eq 'ratelimit') -and
            ([Math]::Abs([double]$fire.rec.cost - 0.0001) -lt 1e-9) -and
            ([string]$fire.rec.resets_at -eq $end.ToString('yyyy-MM-dd HH:mm')) -and
            $once -and ([string]$once.rec.label -eq 'chase ratelimits') -and $at -and ([Math]::Abs(($at - $end.AddMinutes(2)).TotalSeconds) -lt 30) -and
            ($r.reg.Count -eq 1) -and $cache -and ($cache.source -eq 'fire') -and ($cache.rate_limits.five_hour.used_percentage -eq 32)
    }
    Test-Case 'fire integration: the ping''s own rate limits say it opened a window - that beats the local-activity guess, nothing booked' {
        $end = (Get-Date).AddHours(5).AddMinutes(-3)
        # local activity 2h ago: the old guess would call this a white ping and chase
        $r = Invoke-FireInt { (Get-Date).AddHours(-2) } { $null } '{"rules":[{"days":["Mon"],"reset":"11:07"}]}' '' (New-StubRl $end)
        $fire = $r.journal | Where-Object { $_.ev -eq 'fire' } | Select-Object -First 1
        $fire -and $fire.rec.ok -and ($fire.rec.anchored -eq $true) -and ([string]$fire.rec.anchor_src -eq 'ratelimit') -and
            ($r.reg.Count -eq 0) -and ($r.toast -like 'True|True|*')
    }
    Test-Case 'fire integration: a usage-limit hit in the stream fails once (no retries), says limit, and still refreshes the cache' {
        Remove-Item (Join-Path $Tmp 'state-ratelimits.json') -ErrorAction SilentlyContinue
        $res = '{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached"}'
        $r = Invoke-FireInt { (Get-Date).AddHours(-1) } { $null } '{"rules":[{"days":["Mon"],"reset":"11:07"}]}' '' (New-StubRl (Get-Date).AddHours(2)) $res
        $fire = $r.journal | Where-Object { $_.ev -eq 'fire' } | Select-Object -First 1
        $cache = $null
        try { $cache = Get-Content (Join-Path $Tmp 'state-ratelimits.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        $fire -and (-not $fire.rec.ok) -and ([string]$fire.rec.kind -eq 'limit') -and ($fire.rec.attempts -eq 1) -and
            (-not $fire.rec.PSObject.Properties['anchored']) -and ($r.reg.Count -eq 0) -and ($r.toast -eq 'False||limit|') -and
            $cache -and ($cache.rate_limits.five_hour.used_percentage -eq 32)
    }
    Test-Case 'fire integration: a follow-up that rides a window again books nothing more (once per gap)' {
        $sched = '{"rules":[{"days":["Mon","Tue","Wed","Thu","Fri","Sat","Sun"],"reset":"' + (Get-Date).AddHours(11).ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) + '"}]}'
        # this fire IS the follow-up booked for a minute ago (its one-shot came due)
        $due = (Get-Date).AddMinutes(-1)
        $self = 'ClaudePreheat-Once-' + $due.ToString('yyyyMMdd-HHmm', [System.Globalization.CultureInfo]::InvariantCulture)
        $seed = '{"ev":"schedule-once","fireAt":"' + $due.ToString('s', [System.Globalization.CultureInfo]::InvariantCulture) + '","label":"chase ratelimits","ts":"' + (Get-Date).AddHours(-3).ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture) + '"}'
        $r = Invoke-FireInt { (Get-Date).AddMinutes(-5) } { $null } $sched $seed (New-StubRl (Get-Date).AddMinutes(40)) '' $self
        $fire = $r.journal | Where-Object { $_.ev -eq 'fire' } | Select-Object -First 1
        $skip = $r.journal | Where-Object { $_.ev -eq 'chase-skip' } | Select-Object -First 1
        $fire -and $fire.rec.ok -and ($fire.rec.anchored -eq $false) -and ($r.reg.Count -eq 0) -and
            $skip -and ([string]$skip.rec.reason -like '*follow-up*') -and ($r.toast -eq 'True|False||')
    }
    Test-Case 'fire integration: without a rate_limit_event the fire falls back to the local-activity guess and says so' {
        $r = Invoke-FireInt { (Get-Date).AddHours(-10) } { $null } '{"rules":[{"days":["Mon"],"reset":"11:07"}]}'
        $fire = $r.journal | Where-Object { $_.ev -eq 'fire' } | Select-Object -First 1
        $fire -and ($fire.rec.anchored -eq $true) -and ([string]$fire.rec.anchor_src -eq 'activity') -and (-not $fire.rec.PSObject.Properties['resets_at'])
    }
    Test-Case 'fire integration: a Claude fire record stays provider-less (old journals, old panels read it unchanged)' {
        $r = Invoke-FireInt { (Get-Date).AddHours(-10) } { $null } '{"rules":[{"days":["Mon"],"reset":"11:07"}]}'
        $fire = $r.journal | Where-Object { $_.ev -eq 'fire' } | Select-Object -First 1
        $fire -and $fire.rec.ok -and (-not $fire.rec.PSObject.Properties['provider'])
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

    Test-Case 'learn auto keeps every other schedule.json key ("chase": false, proxy, other sections)' {
        # regression: learn auto rebuilt the file from _readme/proxy/rules only
        # and silently turned follow-ups back on
        $c0 = '{"_readme":"old","proxy":"http://127.0.0.1:7890","chase":false,"extra":{"rules":[{"days":["Sun"],"reset":"15:00"}]},"rules":[]}' | ConvertFrom-Json
        $out = New-LearnedConfig $c0 @([ordered]@{ days = @('Mon'); reset = '10:00' })
        $j = ConvertTo-Json -InputObject $out -Depth 8 | ConvertFrom-Json
        ($j.chase -eq $false) -and ($j.proxy -eq 'http://127.0.0.1:7890') -and
            (@($j.extra.rules[0].days).Count -eq 1) -and ($j.extra.rules[0].days[0] -eq 'Sun') -and
            (@($j.rules).Count -eq 1) -and ($j.rules[0].reset -eq '10:00') -and ($j._readme -eq 'old')
    }
    Test-Case 'learn auto with no schedule.json yet writes an empty proxy, the rules and a _readme that explains chase' {
        $j = ConvertTo-Json -InputObject (New-LearnedConfig $null @([ordered]@{ days = @('Tue', 'Wed'); reset = '14:00' })) -Depth 8 | ConvertFrom-Json
        ($j.proxy -eq '') -and (@($j.rules).Count -eq 1) -and (@($j.rules[0].days).Count -eq 2) -and
            (-not $j.PSObject.Properties['chase']) -and ($j._readme -like '*chase: false*')
    }

    Write-Host '-- preheat: one-shots name themselves (-Job) --'
    Test-Case 'a one-shot passes its own name as -Job, so a Windows fire can tell it is a follow-up' {
        # a Windows task has no environment block; launchd sets CLAUDE_PREHEAT_SELF in the plist
        $LogPath = Join-Path $Tmp 'once-job.jsonl'
        $script:OnceReg = $null
        function Register-PreheatJob { param([string]$Name, [string[]]$Days, [datetime]$At, [switch]$NoWake, [string[]]$ScriptArgs) $script:OnceReg = @{ name = $Name; args = @($ScriptArgs) } }
        Invoke-Once ((Get-Date).AddHours(2)) 'test' 6>$null
        $r = $script:OnceReg
        ($r.name -like 'ClaudePreheat-Once-*') -and ($r.args.Count -eq 3) -and
            ($r.args[0] -eq 'fire') -and ($r.args[1] -eq '-Job') -and ($r.args[2] -eq $r.name)
    }
    Test-Case '-Job names the running job: only a ClaudePreheat-* name, never over an existing value' {
        $prev = $env:CLAUDE_PREHEAT_SELF
        $ps = Join-Path $Repo 'preheat.ps1'
        try {
            Remove-Item Env:CLAUDE_PREHEAT_SELF -ErrorAction SilentlyContinue
            & { . $ps '__selftest__' -Job 'ClaudePreheat-Once-20990101-0000' 6>$null | Out-Null }
            $a = $env:CLAUDE_PREHEAT_SELF
            Remove-Item Env:CLAUDE_PREHEAT_SELF -ErrorAction SilentlyContinue
            & { . $ps '__selftest__' -Job '..\..\not-a-job' 6>$null | Out-Null }
            $b = $env:CLAUDE_PREHEAT_SELF
            $env:CLAUDE_PREHEAT_SELF = 'ClaudePreheat-Wk-0400-Sat'
            & { . $ps '__selftest__' -Job 'ClaudePreheat-Once-20990101-0000' 6>$null | Out-Null }
            $c = $env:CLAUDE_PREHEAT_SELF
            ($a -eq 'ClaudePreheat-Once-20990101-0000') -and (-not $b) -and ($c -eq 'ClaudePreheat-Wk-0400-Sat')
        } finally {
            if ($prev) { $env:CLAUDE_PREHEAT_SELF = $prev } else { Remove-Item Env:CLAUDE_PREHEAT_SELF -ErrorAction SilentlyContinue }
        }
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
    Test-Case 'plist passes extra script args after fire, each its own <string> (default stays bare fire)' {
        $x1 = Build-LaunchdPlist -Name 'ClaudePreheat-Once-20260824-1530' -Days @() -At ([datetime]::new(2026, 8, 24, 15, 30, 0)) `
            -HostShell '/p' -ScriptPath '/s' -PathEnv '/b' -ScriptArgs @('fire', '-Job', 'ClaudePreheat-Once-20260824-1530')
        $x0 = Build-LaunchdPlist -Name 'ClaudePreheat-Wk-0400-Sat' -Days @('Saturday') -At ([datetime]::new(2026, 1, 1, 4, 0, 0)) `
            -HostShell '/p' -ScriptPath '/s' -PathEnv '/b'
        ($x1 -match '<string>/s</string>\s*<string>fire</string>\s*<string>-Job</string>\s*<string>ClaudePreheat-Once-20260824-1530</string>\s*</array>') -and
            ($x0 -match '<string>/s</string>\s*<string>fire</string>\s*</array>')
    }
    Test-Case 'task action line: default ends in "fire"; a one-shot appends "-Job" "<name>"' {
        $a0 = Get-PreheatActionArgument 'C:\r\run-hidden.vbs' 'C:\pw\pwsh.exe' 'C:\r\preheat.ps1'
        $a1 = Get-PreheatActionArgument 'C:\r\run-hidden.vbs' 'C:\pw\pwsh.exe' 'C:\r\preheat.ps1' @('fire', '-Job', 'ClaudePreheat-Once-20990101-0000')
        ($a0 -eq '//B //Nologo "C:\r\run-hidden.vbs" "C:\pw\pwsh.exe" "-NoProfile" "-ExecutionPolicy" "Bypass" "-File" "C:\r\preheat.ps1" "fire"') -and
            ($a1 -like '* "-File" "C:\r\preheat.ps1" "fire" "-Job" "ClaudePreheat-Once-20990101-0000"')
    }
    Test-Case 'trigger boundary = local wall-clock time, no UTC offset, culture-proof (DST keeps 05:00 at 05:00)' {
        $th = [System.Threading.Thread]::CurrentThread
        $c0 = $th.CurrentCulture
        try {
            $th.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('fi-FI')
            (Format-LocalBoundary ([datetime]::new(2026, 11, 1, 5, 0, 0))) -eq '2026-11-01T05:00:00'
        } finally { $th.CurrentCulture = $c0 }
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

    Write-Host '-- platform: real Task Scheduler (Windows only) --'
    $winOnly = $true
    try { if (($PSVersionTable.PSEdition -eq 'Core') -and (-not $IsWindows)) { $winOnly = $false } } catch { }
    function Register-SelftestJob([string]$Kind, [datetime]$At) {
        # NOT ClaudePreheat-*: apply / off / the one-shot sweep never see it, and
        # it runs a harmless 'status' - a killed test run must not leave a weekly
        # task behind that pings claude. -> task, or 'SKIP' where policy forbids
        $n = 'zzPreheatSelftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        try {
            if ($Kind -eq 'weekly') { Register-PreheatJob -Name $n -Days @($At.DayOfWeek.ToString()) -At $At -NoWake -ScriptArgs @('status') }
            else { Register-PreheatJob -Name $n -At $At -NoWake -ScriptArgs @('status') }
        } catch {
            if ($_.Exception.Message -match 'denied|0x80070005') { return 'SKIP' }
            throw
        }
        Get-ScheduledTask -TaskName $n
    }
    Test-Case 'Windows: a registered weekly task keeps an offset-less boundary and its local fire time' {
        if (-not $winOnly) { return 'SKIP' }
        $at = (Get-Date).Date.AddDays(1).AddHours(5)
        $t = Register-SelftestJob 'weekly' $at
        if ($t -eq 'SKIP') { return 'SKIP' }
        try {
            $sb   = [string]$t.Triggers[0].StartBoundary
            $next = ($t | Get-ScheduledTaskInfo).NextRunTime
            ($sb -eq (Format-LocalBoundary $at)) -and ($next -eq $at) -and ($t.Actions[0].Arguments -like '*"status"')
        } finally { Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue }
    }
    Test-Case 'Windows: a registered one-shot keeps an absolute instant (a chase is computed from a UTC end)' {
        if (-not $winOnly) { return 'SKIP' }
        $n0 = (Get-Date).AddHours(3)
        $at = [datetime]::new($n0.Year, $n0.Month, $n0.Day, $n0.Hour, $n0.Minute, 0)
        $t = Register-SelftestJob 'once' $at
        if ($t -eq 'SKIP') { return 'SKIP' }
        try {
            $sb   = [string]$t.Triggers[0].StartBoundary
            $next = ($t | Get-ScheduledTaskInfo).NextRunTime
            ($sb -match '(Z|[+-]\d\d:\d\d)$') -and ($next -eq $at)
        } finally { Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue }
    }
    Test-Case 'Windows: the real task argument line binds fire and -Job through wscript + run-hidden.vbs' {
        if (-not $winOnly) { return 'SKIP' }
        # the dot-sourced -Job case above never crosses the vbs shim: this one
        # runs the exact line a one-shot task runs, against a probe script with
        # preheat.ps1's own parameter block
        $probe = Join-Path $Tmp 'job-probe.ps1'
        $out   = Join-Path $Tmp 'job-probe.txt'
        Set-Content -Path $probe -Encoding ASCII -Value @(
            'param([Parameter(Position = 0)][string]$Command, [Parameter(Position = 1)][string]$Arg, [switch]$Json, [string]$Job)',
            ('Set-Content -Path ''{0}'' -Value (''cmd=['' + $Command + ''] arg=['' + $Arg + ''] job=['' + $Job + '']'') -Encoding ASCII' -f $out)
        )
        $line = Get-PreheatActionArgument (Join-Path $Repo 'run-hidden.vbs') (Get-Process -Id $PID).Path $probe @('fire', '-Job', 'ClaudePreheat-Once-20990101-0000')
        $p = Start-Process -FilePath 'wscript.exe' -ArgumentList $line -PassThru -Wait
        $null = $p.Handle
        ($p.ExitCode -eq 0) -and ((Get-Content $out -Raw).Trim() -eq 'cmd=[fire] arg=[] job=[ClaudePreheat-Once-20990101-0000]')
    }
    Test-Case 'a wall-clock time skipped by the spring DST change moves to a registrable one' {
        $z = $null
        foreach ($id in @('Eastern Standard Time', 'America/New_York')) {
            try { $z = [System.TimeZoneInfo]::FindSystemTimeZoneById($id); break } catch { }
        }
        if (-not $z) { return 'SKIP' }
        $gap = [datetime]::new(2027, 3, 14, 2, 30, 0)
        $ok  = [datetime]::new(2027, 3, 14, 4, 30, 0)
        ((Get-RegistrableTime $gap $true $z) -eq $gap.AddDays(1)) -and
            ((Get-RegistrableTime $gap $false $z) -eq $gap.AddHours(1)) -and
            ((Get-RegistrableTime $ok $true $z) -eq $ok)
    }
    Test-Case 'Windows triggers are registered with an offset-less boundary (static guard)' {
        (Get-Content (Join-Path $Repo 'platform.ps1') -Raw) -match '\$trigger\.StartBoundary\s*=\s*Format-LocalBoundary\s+\$At'
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

    # ======================================================== Codex (beta)
    Write-Host '-- codex: windows + verdicts (pure, codex.ps1) --'
    # rateLimits/read payloads in the app-server's camelCase shape
    $cxW  = { param([int]$Mins, [long]$Reset, $Used = 12) '{"usedPercent":' + $Used + ',"windowDurationMins":' + $Mins + ',"resetsAt":' + $Reset + '}' }
    $cxRl = {
        param([string]$Primary, [string]$Secondary, [string]$Plan = 'plus', [switch]$NoById)
        $snap = '{"limitId":"codex","planType":"' + $Plan + '"'
        if ($Primary) { $snap += ',"primary":' + $Primary }
        if ($Secondary) { $snap += ',"secondary":' + $Secondary }
        $snap += '}'
        $j = '{"rateLimits":' + $snap
        if (-not $NoById) { $j += ',"rateLimitsByLimitId":{"codex":' + $snap + '}' }
        ($j + '}') | ConvertFrom-Json
    }
    $N0 = [long]1790000000
    Test-Case 'Get-CodexWindows: the 300-min window is the 5h one, the 10080-min one weekly; plan and bucket read through' {
        $w = Get-CodexWindows (& $cxRl (& $cxW 300 ($N0 + 3600)) (& $cxW 10080 ($N0 + 86400) 40))
        $w.five -and ($w.five.mins -eq 300) -and ([long]$w.five.resetsAt -eq ($N0 + 3600)) -and ($w.five.used -eq 12) -and
            $w.weekly -and ($w.weekly.mins -eq 10080) -and ($w.plan -eq 'plus') -and ($w.bucket -eq 'codex')
    }
    Test-Case 'Get-CodexWindows: classified by duration only - swapped slots, 302 min inside the tolerance, 330 outside, planType ignored' {
        $sw   = Get-CodexWindows (& $cxRl (& $cxW 10080 ($N0 + 86400)) (& $cxW 300 ($N0 + 3600)))
        $near = Get-CodexWindows (& $cxRl (& $cxW 302 ($N0 + 3600)) '')
        $far  = Get-CodexWindows (& $cxRl (& $cxW 330 ($N0 + 3600)) '')
        $plusNo  = Get-CodexWindows (& $cxRl (& $cxW 10080 ($N0 + 86400)) '' 'plus')
        $freeYes = Get-CodexWindows (& $cxRl (& $cxW 300 ($N0 + 3600)) '' 'free')
        $sw.five -and ([long]$sw.five.resetsAt -eq ($N0 + 3600)) -and $sw.weekly -and $near.five -and (-not $far.five) -and
            (-not $plusNo.five) -and $freeYes.five
    }
    Test-Case 'Get-CodexWindows: a free 30-day window is NOT a 5h window, no windows at all (pro) gives neither, every window still listed' {
        $free = Get-CodexWindows (& $cxRl (& $cxW 43200 ($N0 + 864000) 5) '' 'free')
        $pro  = Get-CodexWindows (& $cxRl '' '' 'pro')
        (-not $free.five) -and (-not $free.weekly) -and ($free.plan -eq 'free') -and
            (@($free.all | Where-Object { $_.mins -eq 43200 }).Count -ge 1) -and
            (-not $pro.five) -and (-not $pro.weekly) -and ($pro.plan -eq 'pro')
    }
    Test-Case 'Get-CodexWindows: prefers rateLimitsByLimitId.codex, falls back to the single-bucket rateLimits of an older binary' {
        $both = ('{"rateLimits":{"planType":"plus","primary":' + (& $cxW 300 ($N0 + 100)) + '},"rateLimitsByLimitId":{"codex":{"planType":"plus","primary":' + (& $cxW 300 ($N0 + 200)) + '}}}') | ConvertFrom-Json
        $old  = & $cxRl (& $cxW 300 ($N0 + 300)) '' 'plus' -NoById
        ([long](Get-CodexWindows $both).five.resetsAt -eq ($N0 + 200)) -and ([long](Get-CodexWindows $old).five.resetsAt -eq ($N0 + 300))
    }
    $cxFive = { param($Reset, $Used = 12) @{ plan = 'plus'; bucket = 'codex'; five = @{ used = $Used; resetsAt = $Reset; mins = 300 }; weekly = $null; all = @() } }
    $cxNone = { param([string]$Plan) @{ plan = $Plan; bucket = 'codex'; five = $null; weekly = $null; all = @() } }
    Test-Case 'Get-CodexPreVerdict: idle (no reset, a past reset, or >= 290 min left) pings with the skew; 0 < left < 290 min is a running window' {
        $a = Get-CodexPreVerdict (& $cxFive $null) $N0
        $b = Get-CodexPreVerdict (& $cxFive ($N0 - 10)) $N0
        $c = Get-CodexPreVerdict (& $cxFive ($N0 + 18000 - 5)) $N0
        $d = Get-CodexPreVerdict (& $cxFive ($N0 + 17400)) $N0
        $e = Get-CodexPreVerdict (& $cxFive ($N0 + 17399)) $N0
        $f = Get-CodexPreVerdict (& $cxFive ($N0 + 1800)) $N0
        ($a.action -eq 'ping') -and (-not $a.windowUnknown) -and ($b.action -eq 'ping') -and
            ($c.action -eq 'ping') -and ([long]$c.idleValue -eq ($N0 + 17995)) -and ([long]$c.skewSec -eq -5) -and
            ($d.action -eq 'ping') -and ($e.action -eq 'skip-running') -and
            ($f.action -eq 'skip-running') -and ([long]$f.resetsAt -eq ($N0 + 1800)) -and ($null -eq $f.idleValue)
    }
    Test-Case 'Get-CodexPreVerdict: a used-up window skips; no 5h window skips on free/go/pro only, any other plan pings blind' {
        $g    = Get-CodexPreVerdict (& $cxFive ($N0 + 3600) 100) $N0
        $free = Get-CodexPreVerdict (& $cxNone 'free') $N0
        $go   = Get-CodexPreVerdict (& $cxNone 'go') $N0
        $pro  = Get-CodexPreVerdict (& $cxNone 'pro') $N0
        $plus = Get-CodexPreVerdict (& $cxNone 'plus') $N0
        $team = Get-CodexPreVerdict (& $cxNone 'team') $N0
        ($g.action -eq 'skip-running') -and ($free.action -eq 'skip-no5h') -and ($go.action -eq 'skip-no5h') -and ($pro.action -eq 'skip-no5h') -and
            ($plus.action -eq 'ping') -and ($plus.windowUnknown -eq $true) -and ($team.action -eq 'ping') -and ($team.windowUnknown -eq $true)
    }
    Test-Case 'Get-CodexPreVerdict: a weekly limit (rateLimitReachedType) on an idle 5h window still pings; plan ids match whole (pro_x yes, prolite no)' {
        $wk = & $cxFive ($N0 + 18000)
        $wk.reached = 'secondary'
        $a = Get-CodexPreVerdict $wk $N0
        ($a.action -eq 'ping') -and ($null -ne $a.idleValue) -and
            ((Get-CodexPreVerdict (& $cxNone 'pro_x') $N0).action -eq 'skip-no5h') -and
            ((Get-CodexPreVerdict (& $cxNone 'prolite') $N0).action -eq 'ping') -and
            ((Get-CodexPreVerdict (& $cxNone 'gopher') $N0).action -eq 'ping')
    }
    $cxRd  = { param([long]$Epoch, [long]$Reset) @{ epoch = $Epoch; windows = @{ plan = 'plus'; bucket = 'codex'; five = @{ used = 1; resetsAt = $Reset; mins = 300 }; weekly = $null; all = @() } } }
    $cxPre = @{ action = 'ping'; resetsAt = ($N0 + 18000); idleValue = ($N0 + 18000); skewSec = 0; windowUnknown = $false }
    Test-Case 'Get-CodexPostVerdict: frozen at pre-read + elapsed = anchored; frozen earlier = moved; frozen later = unknown; still sliding = sliding' {
        # ping 5..25s after the pre-read: expected freeze E = N0+18005, accepted [E-30, E+20+30]
        $anch  = Get-CodexPostVerdict $cxPre $N0 ($N0 + 5) ($N0 + 25) @((& $cxRd ($N0 + 85) ($N0 + 18010)), (& $cxRd ($N0 + 115) ($N0 + 18010)))
        $moved = Get-CodexPostVerdict $cxPre $N0 ($N0 + 5) ($N0 + 25) @((& $cxRd ($N0 + 85) ($N0 + 17000)), (& $cxRd ($N0 + 115) ($N0 + 17000)))
        $high  = Get-CodexPostVerdict $cxPre $N0 ($N0 + 5) ($N0 + 25) @((& $cxRd ($N0 + 85) ($N0 + 18200)), (& $cxRd ($N0 + 115) ($N0 + 18200)))
        $slide = Get-CodexPostVerdict $cxPre $N0 ($N0 + 5) ($N0 + 25) @((& $cxRd ($N0 + 85) ($N0 + 18085)), (& $cxRd ($N0 + 115) ($N0 + 18115)), (& $cxRd ($N0 + 235) ($N0 + 18235)))
        ($anch.state -eq 'anchored') -and ([long]$anch.resetsAt -eq ($N0 + 18010)) -and
            ($moved.state -eq 'moved') -and ([long]$moved.resetsAt -eq ($N0 + 17000)) -and
            ($high.state -eq 'unknown') -and ($slide.state -eq 'sliding') -and ($null -eq $anch.lagSec)
    }
    Test-Case 'Get-CodexPostVerdict: a window that opens between two post reads (slid, then froze) is anchored with its lag, not unknown' {
        # idle pre-read at N0 (N0+18000), ping 5..25: the window opens at N0+100 (between the 60s and 90s reads)...
        $a = Get-CodexPostVerdict $cxPre $N0 ($N0 + 5) ($N0 + 25) @((& $cxRd ($N0 + 85) ($N0 + 18085)), (& $cxRd ($N0 + 115) ($N0 + 18100)))
        # ...or at N0+200, between the second read and the confirm read
        $b = Get-CodexPostVerdict $cxPre $N0 ($N0 + 5) ($N0 + 25) @((& $cxRd ($N0 + 85) ($N0 + 18085)), (& $cxRd ($N0 + 115) ($N0 + 18115)), (& $cxRd ($N0 + 235) ($N0 + 18200)))
        ($a.state -eq 'anchored') -and ([long]$a.resetsAt -eq ($N0 + 18100)) -and ([long]$a.lagSec -eq 75) -and
            ($b.state -eq 'anchored') -and ([long]$b.resetsAt -eq ($N0 + 18200)) -and ([long]$b.lagSec -eq 175)
    }
    Test-Case 'Test-CodexMetered: a window that opened ~3 min ago (still > 290 min left) counts as metered after an idle pre-read' {
        $frozen = & $cxFive ($N0 + 18010)
        $idle   = & $cxFive ($N0 + 18180)
        $blind  = @{ action = 'ping'; resetsAt = $null; idleValue = $null; skewSec = $null; windowUnknown = $true }
        (Test-CodexMetered $cxPre $N0 $frozen ($N0 + 180)) -and (-not (Test-CodexMetered $cxPre $N0 $idle ($N0 + 180))) -and
            (-not (Test-CodexMetered $blind $N0 $frozen ($N0 + 180))) -and (Test-CodexMetered $blind $N0 (& $cxFive ($N0 + 3600)) ($N0 + 180))
    }
    Test-Case 'Get-CodexPostVerdict: only the confirm read froze (late metering) -> the last pair decides and the lag is reported' {
        # no idle value from the pre-read: expected E = ping start + 5h, accepted +-600s
        $preU = @{ action = 'ping'; resetsAt = $null; idleValue = $null; skewSec = $null; windowUnknown = $false }
        $lag = Get-CodexPostVerdict $preU $N0 ($N0 + 5) ($N0 + 25) @((& $cxRd ($N0 + 85) ($N0 + 18085)), (& $cxRd ($N0 + 115) ($N0 + 18115)), (& $cxRd ($N0 + 235) ($N0 + 18115)))
        ($lag.state -eq 'anchored') -and ([long]$lag.resetsAt -eq ($N0 + 18115)) -and ($lag.lagSec -gt 0)
    }
    $cxStreamOk = @(
        '{"type":"thread.started","thread_id":"stub-thread-1"}',
        '{"type":"turn.started"}',
        'not json at all',
        '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"hi"}}',
        '{"type":"turn.completed","usage":{"input_tokens":16900,"cached_input_tokens":12000,"output_tokens":5,"reasoning_output_tokens":0}}'
    ) -join "`n"
    Test-Case 'ConvertFrom-CodexExecStream: thread id, the four token counts apart, agent_message text, junk lines skipped' {
        $s = ConvertFrom-CodexExecStream $cxStreamOk
        ($s.threadId -eq 'stub-thread-1') -and $s.sawTokens -and ($s.tokens.input -eq 16900) -and ($s.tokens.cached -eq 12000) -and
            ($s.tokens.output -eq 5) -and ($s.tokens.reasoning -eq 0) -and $s.agentText -and (@($s.errors).Count -eq 0)
    }
    Test-Case 'ConvertFrom-CodexExecStream: a failed turn carries its errors and no tokens; empty output is nothing' {
        $bad = ConvertFrom-CodexExecStream (@(
            '{"type":"thread.started","thread_id":"t2"}',
            '{"type":"error","message":"You have hit your usage limit. Try again later."}',
            '{"type":"turn.failed","error":{"message":"usage limit reached"}}') -join "`r`n")
        $none = ConvertFrom-CodexExecStream ''
        (-not $bad.sawTokens) -and (@($bad.errors).Count -ge 1) -and (-not $bad.agentText) -and (-not $none.sawTokens) -and (-not $none.agentText)
    }
    Test-Case 'Get-CodexFailureKind: login trouble -> auth, a hit limit -> limit, clap usage -> usage-error, the rest -> other' {
        ((Get-CodexFailureKind 'Error: Not logged in' 1) -eq 'auth') -and
            ((Get-CodexFailureKind '{"error":"refresh_token_reused"}' 1) -eq 'auth') -and
            ((Get-CodexFailureKind 'HTTP 401 Unauthorized' 1) -eq 'auth') -and
            ((Get-CodexFailureKind 'You have hit your usage limit. Try again later.' 1) -eq 'limit') -and
            ((Get-CodexFailureKind ("error: unexpected argument '--ignore-rules' found`n`nUsage: codex exec [OPTIONS] [PROMPT]") 2) -eq 'usage-error') -and
            ((Get-CodexFailureKind 'connection reset by peer' 1) -eq 'other')
    }
    Test-Case 'Get-MaskedEmail / Protect-ReportText: no email, token, key, home path (any spelling) or user name survives' {
        $homeP = [Environment]::GetFolderPath('UserProfile')
        $user  = [Environment]::UserName
        $fwd   = $homeP -replace '\\', '/'
        $jsonP = $homeP -replace '\\', '\\'
        $txt = 'mail bob.smith@corp.example | jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.c2lnbmF0dXJlLXN0dWZm | key sk-proj-ABCDEFGHIJKLMNOPQRST123456 | ' +
            'path ' + $homeP + '\.codex\x | fwd ' + $fwd + '/.codex | json ' + $jsonP + '\\.codex | user ' + $user + ' | done'
        $o = Protect-ReportText $txt
        $ok = ((Get-MaskedEmail 'alice@example.com') -eq 'a***@example.com') -and
            ($o -notmatch 'bob\.smith') -and ($o -notmatch 'eyJhbGci') -and ($o -notmatch 'sk-proj-ABCDEF') -and
            (-not $o.Contains($homeP)) -and (-not $o.Contains($fwd)) -and (-not $o.Contains($jsonP)) -and ($o -like '*done*')
        if (($user.Length -ge 4) -and ($user -notmatch '^\d+$')) { $ok = $ok -and ($o -notmatch ('\b' + [regex]::Escape($user) + '\b')) }
        # an all-digit user name must not rewrite ordinary numbers (ms=, drift_s=)
        $prevU = $env:USERNAME; $prevV = $env:USER
        try { $env:USERNAME = '24680'; $env:USER = '24680'; $d = Protect-ReportText 'ms=24680 drift_s=24680 D:\Users\24680\x' }
        finally { $env:USERNAME = $prevU; $env:USER = $prevV }
        $ok -and ($d -eq ('ms=24680 drift_s=24680 D:\Users\<user>\x'))
    }
    Test-Case 'Invoke-CodexRpc: a method outside the allow-list throws BLOCKED before a single byte is written' {
        $w = New-Object System.IO.StringWriter
        $s = [pscustomobject]@{ In = $w; Proc = $null; NextId = 0; TimeoutSec = 1; Restarting = $false }
        $m = ''
        try { $null = Invoke-CodexRpc $s 'account/rateLimitResetCredit/consume' @{} } catch { $m = $_.Exception.Message }
        ($m -like 'BLOCKED*') -and ($w.ToString() -eq '') -and ($s.NextId -eq 0)
    }
    Test-Case 'Get-CodexConfigPassthrough: only the four login keys, only from the top level of config.toml; no file -> nothing' {
        $ch = Join-Path $Tmp 'cx-config-home'
        New-Item -ItemType Directory -Path $ch -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $ch 'config.toml'), (@(
            'model = "gpt-5"', 'cli_auth_credentials_store = "keyring"', 'forced_login_method = "chatgpt"',
            'chatgpt_base_url = "https://proxy.example/backend-api/"', '', '[profiles.work]', 'forced_chatgpt_workspace_id = "ws-in-a-table"', '') -join "`n"))
        $p = @(Get-CodexConfigPassthrough $ch)
        $flat = $p -join ' '
        ($p.Count -eq 6) -and (@($p | Where-Object { $_ -ceq '-c' }).Count -eq 3) -and
            ($flat -match 'cli_auth_credentials_store=') -and ($flat -match 'forced_login_method=') -and ($flat -match 'chatgpt_base_url=') -and
            ($flat -notmatch 'model=') -and ($flat -notmatch 'ws-in-a-table') -and
            (@(Get-CodexConfigPassthrough (Join-Path $Tmp 'no-codex-home')).Count -eq 0)
    }
    Test-Case 'Get-CodexHome / Use-CodexEnvironment: CODEX_HOME wins over ~/.codex; the proxy and codex.home from schedule.json reach the env children inherit' {
        $snap = Get-CxEnvSnapshot
        try {
            $env:CODEX_HOME = Join-Path $Tmp 'cxh'
            $a = Get-CodexHome
            Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
            $b = Get-CodexHome
            $h2 = Join-Path $Tmp 'cxh2'
            Use-CodexEnvironment ([pscustomobject]@{ proxy = 'http://127.0.0.1:9'; rules = @(); codex = [pscustomobject]@{ rules = @(); home = $h2 } })
            ($a -eq (Join-Path $Tmp 'cxh')) -and ((Split-Path $b -Leaf) -eq '.codex') -and
                ($env:HTTPS_PROXY -eq 'http://127.0.0.1:9') -and ($env:HTTP_PROXY -eq 'http://127.0.0.1:9') -and ($env:CODEX_HOME -eq $h2)
        } finally { Restore-CxEnvSnapshot $snap }
    }

    Write-Host '-- codex: job names, journal, chase (pure) --'
    Test-Case 'Codex job names: own provider, decode like their Claude twins, launchd round-trip, spent check' {
        $now = & $D '2026-09-13 15:00'
        $n = Get-JobNextRun 'ClaudePreheat-Codex-Wk-0745-TueWedThu'
        ((Get-JobProvider 'ClaudePreheat-Codex-Wk-0400-Mon') -eq 'codex') -and ((Get-JobProvider 'ClaudePreheat-Codex-Once-20261231-1530') -eq 'codex') -and
            ((Get-JobProvider 'ClaudePreheat-Wk-0400-Mon') -eq 'claude') -and ((Get-JobProvider 'ClaudePreheat-Once-20261231-1530') -eq 'claude') -and
            ((Get-JobNextRun 'ClaudePreheat-Codex-Once-20261231-1530') -eq ([datetime]::new(2026, 12, 31, 15, 30, 0))) -and
            $n -and ($n.Hour -eq 7) -and ($n.Minute -eq 45) -and
            ((ConvertTo-LaunchdLabel 'ClaudePreheat-Codex-Wk-0400-Sat') -eq 'com.claude-preheat.Codex-Wk-0400-Sat') -and
            ((ConvertFrom-LaunchdLabel 'com.claude-preheat.Codex-Once-20261231-1530') -eq 'ClaudePreheat-Codex-Once-20261231-1530') -and
            (Test-SpentOnce @{ name = 'ClaudePreheat-Codex-Once-20260913-1400'; next = $null } $now) -and
            (-not (Test-SpentOnce @{ name = 'ClaudePreheat-Codex-Once-20260913-1638'; next = (& $D '2026-09-13 16:38') } $now)) -and
            (-not (Test-SpentOnce @{ name = 'ClaudePreheat-Codex-Wk-0330-MonTue'; next = $null } $now))
    }
    Test-Case 'a Codex weekly job runs "fire -Provider codex" and bakes no codex binary path (the exe is resolved per fire)' {
        $x = Build-LaunchdPlist -Name 'ClaudePreheat-Codex-Wk-0400-Sat' -Days @('Saturday') -At ([datetime]::new(2026, 1, 1, 4, 0, 0)) `
            -HostShell '/p' -ScriptPath '/repo/preheat.ps1' -PathEnv '/b' -ScriptArgs @('fire', '-Provider', 'codex')
        $a = Get-PreheatActionArgument 'C:\r\run-hidden.vbs' 'C:\pw\pwsh.exe' 'C:\r\preheat.ps1' @('fire', '-Provider', 'codex', '-Job', 'ClaudePreheat-Codex-Once-20990101-0000')
        ($x -match '<string>/repo/preheat.ps1</string>\s*<string>fire</string>\s*<string>-Provider</string>\s*<string>codex</string>\s*</array>') -and
            ($x -like '*com.claude-preheat.Codex-Wk-0400-Sat*') -and ($x -notmatch 'codex(\.exe|\.cmd)') -and
            ($a -like '* "fire" "-Provider" "codex" "-Job" "ClaudePreheat-Codex-Once-20990101-0000"')
    }
    Test-Case 'a Codex one-shot is named for Codex, runs fire -Provider codex -Job <name>, and journals provider codex' {
        $LogPath = Join-Path $Tmp 'cx-once-job.jsonl'
        $script:OnceReg = $null
        function Register-PreheatJob { param([string]$Name, [string[]]$Days, [datetime]$At, [switch]$NoWake, [string[]]$ScriptArgs) $script:OnceReg = @{ name = $Name; args = @($ScriptArgs) } }
        Invoke-Once ((Get-Date).AddHours(2)) 'test' -Provider 'codex' 6>$null
        $r = $script:OnceReg
        $rec = @(Read-JsonLines $LogPath | Where-Object { $_.ev -eq 'schedule-once' })
        ($r.name -like 'ClaudePreheat-Codex-Once-*') -and (($r.args -join ' ') -eq ('fire -Provider codex -Job ' + $r.name)) -and
            ($rec.Count -eq 1) -and ($rec[0].provider -eq 'codex')
    }
    $cxStamp = { param($s) (& $D $s).ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture) }
    Test-Case 'Get-FireEvents filters by provider BEFORE pairing: a same-minute Claude follow-up never lands on a Codex fire' {
        $j = Join-Path $Tmp 'events-providers.jsonl'
        @(
            ('{"ev":"fire","ok":true,"anchored":false,"attempts":1,"ts":"' + (& $cxStamp '2026-09-12 15:00') + '"}'),
            ('{"ev":"fire","provider":"codex","ok":true,"pinged":false,"state":"running","anchored":false,"plan":"plus","resets_at":"2026-09-12 16:30","attempts":0,"ts":"' + (& $cxStamp '2026-09-12 15:00') + '"}'),
            ('{"ev":"schedule-once","fireAt":"2026-09-12T16:39:00","label":"chase ratelimits","ts":"' + (& $cxStamp '2026-09-12 15:00') + '"}'),
            ('{"ev":"schedule-once","provider":"codex","fireAt":"2026-09-12T16:32:00","label":"chase ratelimits","ts":"' + (& $cxStamp '2026-09-12 15:00') + '"}'),
            ('{"ev":"fire","provider":"codex","ok":false,"kind":"no5h","pinged":false,"state":"no5h","attempts":0,"ts":"' + (& $cxStamp '2026-09-12 15:30') + '"}')
        ) | Set-Content -Path $j -Encoding UTF8
        $cl = @(Get-FireEvents $j 60)
        $cx = @(Get-FireEvents $j 60 -Provider 'codex')
        ($cl.Count -eq 1) -and ($cl[0].chase_at -eq '2026-09-12 16:39') -and ($cl[0].provider -eq 'claude') -and
            ($cx.Count -eq 2) -and ($cx[0].provider -eq 'codex') -and ($cx[0].kind -eq 'no5h') -and
            ($cx[1].chase_at -eq '2026-09-12 16:32') -and ($cx[1].state -eq 'running') -and ($cx[1].pinged -eq $false) -and ($cx[1].plan -eq 'plus')
    }
    Test-Case 'an old journal with Codex lines mixed in reads exactly as before for Claude (count, order, fields)' {
        $j = Join-Path $Tmp 'events-mixed.jsonl'
        $lines = @(Get-Content (Join-Path $Tmp 'events.jsonl') -Encoding UTF8)
        $mixed = @()
        foreach ($l in $lines) {
            $mixed += $l
            $mixed += '{"ev":"fire","provider":"codex","ok":true,"pinged":true,"state":"anchored","anchored":true,"attempts":1,"ts":"2026-09-12T10:00:00-07:00"}'
        }
        $mixed | Set-Content -Path $j -Encoding UTF8
        $all = @(Get-FireEvents $j 60)
        ($all.Count -eq 3) -and ($all[0].kind -eq 'limit') -and ($all[1].anchored -eq $false) -and ($all[2].anchored -eq $true)
    }
    Test-Case 'the anchor and chase gates read only their own provider (a Codex anchor never blocks a Claude chase, and back)' {
        $j1 = Join-Path $Tmp 'gate-codex.jsonl'
        $before = & $D '2026-09-13 15:00'
        @(
            ('{"ev":"fire","provider":"codex","ok":true,"anchored":true,"ts":"' + (& $cxStamp '2026-09-13 12:30') + '"}'),
            ('{"ev":"schedule-once","provider":"codex","fireAt":"2026-09-13T16:39:00","label":"chase ratelimits","ts":"' + (& $cxStamp '2026-09-13 14:00') + '"}')
        ) | Set-Content -Path $j1 -Encoding UTF8
        $j2 = Join-Path $Tmp 'gate-claude.jsonl'
        @(
            ('{"ev":"fire","ok":true,"anchored":true,"ts":"' + (& $cxStamp '2026-09-13 12:30') + '"}'),
            ('{"ev":"schedule-once","fireAt":"2026-09-13T16:38:00","label":"chase ratelimits","ts":"' + (& $cxStamp '2026-09-13 14:00') + '"}')
        ) | Set-Content -Path $j2 -Encoding UTF8
        (-not (Test-RecentPreheatAnchor $before $j1)) -and (Test-RecentPreheatAnchor $before $j1 -Provider 'codex') -and
            (Test-RecentPreheatAnchor $before $j2) -and (-not (Test-RecentPreheatAnchor $before $j2 -Provider 'codex')) -and
            ($null -eq (Get-LastPreheatAnchor $j1)) -and ($null -ne (Get-LastPreheatAnchor $j1 -Provider 'codex')) -and
            (Test-ChaseFire 'ClaudePreheat-Codex-Once-20260913-1639' $j1 -Provider 'codex') -and
            (-not (Test-ChaseFire 'ClaudePreheat-Once-20260913-1639' $j1)) -and
            (-not (Test-ChaseFire 'ClaudePreheat-Once-20260913-1638' $j2 -Provider 'codex'))
    }
    Test-Case 'the journal readers look 1000 lines back (two providers share the tail)' {
        $j = Join-Path $Tmp 'tail-1000.jsonl'
        $lines = @('{"ev":"fire","ok":true,"anchored":true,"ts":"2026-09-12T04:00:12-07:00"}') + @(@('{"ev":"x"}') * 700)
        $lines | Set-Content -Path $j -Encoding UTF8
        @(Get-JournalEvents $j 5000).Count -eq 701
    }
    Test-Case 'next weekly fire per provider: Codex reads codex.rules, Claude the top-level rules' {
        $ConfigPath = New-Fixture 'sched-cx.json' @('{"rules":[{"days":["Mon","Tue","Wed","Thu","Fri","Sat","Sun"],"reset":"11:07"}],"codex":{"rules":[{"days":["Mon","Tue","Wed","Thu","Fri","Sat","Sun"],"reset":"13:21"}]}}')
        ((Get-NextWeeklyFire (& $D '2026-09-13 15:00')) -eq (& $D '2026-09-14 06:07')) -and
            ((Get-NextWeeklyFire (& $D '2026-09-13 15:00') -Provider 'codex') -eq (& $D '2026-09-14 08:21'))
    }

    Write-Host '-- codex: stub app-server + exec (spawns the stub codex only) --'
    Test-Case 'Resolve-CodexExe honors PREHEAT_CODEX_EXE first (kind env); Get-CodexVersion asks it for --version' {
        $r = Resolve-CodexExe
        $r -and ($r.path -eq $cxStub) -and ($r.kind -eq 'env') -and ((Get-CodexVersion $cxStub) -like '*0.99.0*')
    }
    Test-Case 'Read-CodexQuota: account masked + hashed, plan, both windows; refreshToken false, no credit details, RUST_LOG off, allow-list only' {
        $r5 = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
        Set-CodexStub @{ r5 = $r5 }
        $q = Read-CodexQuota $cxStub -Reads 1 -TimeoutSec 30
        $w = $null
        if ($q.ok -and @($q.reads).Count -ge 1) { $w = Get-CodexWindows @($q.reads)[0].raw }
        $calls = Get-CodexStubCalls
        $q.ok -and ($null -eq $q.kind) -and ($q.account.plan -eq 'plus') -and ($q.account.emailMasked -eq 's***@example.com') -and
            ([string]$q.account.hash -match '^[0-9a-f]{8}$') -and (@($q.reads).Count -eq 1) -and ([long]@($q.reads)[0].epoch -gt 0) -and
            $w -and ([long]$w.five.resetsAt -eq $r5) -and $w.weekly -and
            (@($calls | Where-Object { $_ -like 'rpc account/read*"refreshToken":false*' }).Count -eq 1) -and
            (@($calls | Where-Object { $_ -like 'rpc account/rateLimits/read*"excludeResetCreditDetails":true*' }).Count -eq 1) -and
            (@($calls | Where-Object { $_ -like 'env *rustlog=off*' }).Count -ge 1) -and (Test-CodexAllowList) -and ((Wait-StubPidsGone) -eq 0)
    }
    Test-Case 'Read-CodexQuota -Reads 2: two timed reads, oldest first, through the shadowed sleep' {
        function Start-Sleep { param($Seconds, $Milliseconds) }
        Set-CodexStub @{}
        $q = Read-CodexQuota $cxStub -Reads 2 -IntervalSec 30 -TimeoutSec 30
        $rs = @($q.reads)
        $q.ok -and ($rs.Count -eq 2) -and ([long]$rs[1].epoch -ge [long]$rs[0].epoch) -and (Test-CodexAllowList)
    }
    Test-Case 'Read-CodexQuota: signed out -> auth, API-key login -> apikey (not auth), free 30d -> ok with no 5h window' {
        Set-CodexStub @{ profile = 'signedout' }; $so = Read-CodexQuota $cxStub -TimeoutSec 30
        Set-CodexStub @{ profile = 'apikey' };    $ak = Read-CodexQuota $cxStub -TimeoutSec 30
        Set-CodexStub @{ profile = 'free30d' };   $fr = Read-CodexQuota $cxStub -TimeoutSec 30
        $fw = $null
        if ($fr.ok) { $fw = Get-CodexWindows @($fr.reads)[0].raw }
        (-not $so.ok) -and ($so.kind -eq 'auth') -and (-not $ak.ok) -and ($ak.kind -eq 'apikey') -and
            $fr.ok -and $fw -and (-not $fw.five) -and ($fr.account.plan -eq 'free') -and (Test-CodexAllowList)
    }
    Test-Case 'Read-CodexQuota: a hung app-server times out in seconds and its process tree is gone' {
        Set-CodexStub @{ rpc = 'hang' }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $q = Read-CodexQuota $cxStub -TimeoutSec 3
        $sw.Stop()
        (-not $q.ok) -and ($q.kind -eq 'other') -and ($sw.Elapsed.TotalSeconds -lt 30) -and ((Wait-StubPidsGone) -eq 0)
    }
    Test-Case 'Read-CodexQuota: an app-server that dies after initialize is a clean failure, not a hang' {
        Set-CodexStub @{ rpc = 'crash' }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $q = Read-CodexQuota $cxStub -TimeoutSec 20
        $sw.Stop()
        (-not $q.ok) -and ([string]$q.err) -and ($sw.Elapsed.TotalSeconds -lt 20)
    }
    $cxPitUnit = Join-Path $Tmp 'cx-unit-pit'
    New-Item -ItemType Directory -Path $cxPitUnit -Force | Out-Null
    Test-Case 'Invoke-CodexPing: the stub accepts the read-only ephemeral argv, stdin is already closed (no timeout), tokens counted, config keys passed' {
        Set-CodexStub @{}
        $r = Invoke-CodexPing $cxStub $cxPitUnit @('-c', 'cli_auth_credentials_store="keyring"') -TimeoutSec 60
        $exec = @(Get-CodexStubCalls | Where-Object { $_ -like 'exec stdin=*' })
        $r.ok -and ($r.exit -eq 0) -and $r.stream.sawTokens -and ($r.stream.tokens.input -eq 16900) -and ($r.ms -lt 50000) -and
            ([long]$r.endEpoch -ge [long]$r.startEpoch) -and ($exec.Count -eq 1) -and ($exec[0] -clike '* -c cli_auth_credentials_store="keyring" *') -and
            ($exec[0] -like '*-s read-only*') -and ($exec[0] -like '*--ephemeral*') -and ($exec[0] -like '*--ignore-user-config*')
    }
    Test-Case 'Invoke-CodexPing: limit, auth and an argv the binary refuses each come back as their own kind' {
        Set-CodexStub @{ exec = 'limit' }; $l = Invoke-CodexPing $cxStub $cxPitUnit @() -TimeoutSec 60
        Set-CodexStub @{ exec = 'auth' };  $a = Invoke-CodexPing $cxStub $cxPitUnit @() -TimeoutSec 60
        Set-CodexStub @{ exec = 'usage' }; $u = Invoke-CodexPing $cxStub $cxPitUnit @() -TimeoutSec 60
        (-not $l.ok) -and ($l.kind -eq 'limit') -and (-not $a.ok) -and ($a.kind -eq 'auth') -and (-not $u.ok) -and ($u.kind -eq 'usage-error') -and
            ([string]$u.err).Length -le 400
    }
    Test-Case 'Invoke-CodexPing: a hung exec is killed at the timeout, tree and all' {
        Set-CodexStub @{ exec = 'hang' }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-CodexPing $cxStub $cxPitUnit @() -TimeoutSec 5
        $sw.Stop()
        (-not $r.ok) -and ($sw.Elapsed.TotalSeconds -lt 40) -and ((Wait-StubPidsGone) -eq 0)
    }

    Write-Host '-- codex: fire integration (stub codex; scheduler, toast and sleeps doubled) --'
    # Invoke-CodexFire end to end against the stub, every side effect redirected
    # like Invoke-FireInt above. Sleeps are no-ops except the two waits the
    # frozen/sliding verdict needs between reads ($Wait real seconds instead of
    # 30 and 120: a frozen pair must not also look like a sliding one).
    $cxIntHome = Join-Path $Tmp 'cx-int-home'
    New-Item -ItemType Directory -Path $cxIntHome -Force | Out-Null
    $cxSched = {
        param([string]$CodexExtra = '')
        # Codex fires daily at now + 6h (reset now + 11h): beyond any follow-up window
        '{"proxy":"http://127.0.0.1:9","rules":[],"codex":{"rules":[{"days":["Mon","Tue","Wed","Thu","Fri","Sat","Sun"],"reset":"' +
            (Get-Date).AddHours(11).ToString('HH:mm', $cxInv) + '"}],"home":' + (ConvertTo-Json -InputObject $cxIntHome) + $CodexExtra + '}}'
    }
    function Invoke-CodexFireInt([hashtable]$Stub = @{}, [string]$Config = '', [string]$Seed = '', [string]$Self = '', [int]$Wait = 0, [string]$MacAgentDir = '') {
        # one Codex fire -> @{ fire; recs; reg; toast; calls; state }
        Set-CodexStub $Stub
        $Root           = $Tmp
        $LogPath        = Join-Path $Tmp ('cx-int-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.jsonl')
        if ($Seed) { Set-Content -Path $LogPath -Value $Seed -Encoding UTF8 }
        $FireLock       = Join-Path $Tmp 'cx-int-claude.lock'
        $CodexFireLock  = Join-Path $Tmp 'cx-int.lock'
        $CodexCachePath = Join-Path $Tmp 'state-ratelimits-codex.json'
        $CodexFirePit   = Join-Path $Tmp 'firepit-codex'
        Remove-Item $CodexCachePath -ErrorAction SilentlyContinue
        if (-not $Config) { $Config = & $cxSched }
        $ConfigPath = New-Fixture 'cx-int-sched.json' @($Config)
        if ($MacAgentDir) {
            $OnMac = $true; $LaunchAgentDir = $MacAgentDir
            function launchctl { }
            function Get-MacUid { '501' }
        }
        $script:CxReg = @(); $script:CxToast = @(); $script:CxWait = $Wait
        # never a real codex: no candidate list, no resolver, no fallback to a desktop install
        function Resolve-CodexExe { @{ path = $cxStub; kind = 'env' } }
        function Get-CodexCandidates { param([switch]$First) @{ path = $cxStub; kind = 'env' } }
        function Start-Sleep { param($Seconds, $Milliseconds) if (($script:CxWait -gt 0) -and (($Seconds -eq 30) -or ($Seconds -eq 120))) { Microsoft.PowerShell.Utility\Start-Sleep -Seconds $script:CxWait } }
        function Register-PreheatJob { param([string]$Name, [string[]]$Days, [datetime]$At, [switch]$NoWake, [string[]]$ScriptArgs) $script:CxReg += @{ name = $Name; at = $At; nowake = [bool]$NoWake; args = @($ScriptArgs) } }
        function Remove-StaleOnceJobs { }
        function Remove-PreheatJobs { param([string]$Pattern) }
        function Send-Toast { param($Ok, $Anchored, $Kind, $Extra, [string]$Provider, [string]$Text) $script:CxToast += ('{0}|{1}|{2}|{3}|{4}|{5}' -f $Ok, $Anchored, $Kind, $Extra, $Provider, $Text) }
        function Get-LastLocalActivity { $null }
        $snap = Get-CxEnvSnapshot
        if ($Self) { $env:CLAUDE_PREHEAT_SELF = $Self } else { Remove-Item Env:CLAUDE_PREHEAT_SELF -ErrorAction SilentlyContinue }
        try { Invoke-CodexFire 6>$null | Out-Null } finally { Restore-CxEnvSnapshot $snap }
        $recs = @(Read-JsonLines $LogPath)
        $fire = $recs | Where-Object { ($_.ev -eq 'fire') -and ($_.provider -eq 'codex') } | Select-Object -Last 1
        $st = $null
        if (Test-Path $cxState) { try { $st = [long](([System.IO.File]::ReadAllText($cxState) | ConvertFrom-Json).r5) } catch { } }
        @{ fire = $fire; recs = $recs; reg = @($script:CxReg); toast = @($script:CxToast); calls = @(Get-CodexStubCalls); state = $st }
    }
    function Get-CxRecs($r, [string]$Ev) { @($r.recs | Where-Object { ($_.ev -eq $Ev) -and ($_.provider -eq 'codex') }) }
    function Test-CxNoExec($r) { @($r.calls | Where-Object { $_ -like 'exec stdin=*' }).Count -eq 0 }
    function Test-CxAllowed($r) {
        $ok = @('initialize', 'initialized', 'account/read', 'account/rateLimits/read')
        foreach ($l in @($r.calls | Where-Object { $_ -like 'rpc *' })) { if ($ok -notcontains ($l.Split(' ')[1])) { return $false } }
        $true
    }

    # one run feeds several cases: a running 5h window (R5 = now + 30 min)
    $cxR5Run = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1800
    $cxRun = $null; $cxRunErr = ''
    try {
        # a Claude anchored fire 1h ago must not block the Codex follow-up
        $seedClaude = '{"ev":"fire","ok":true,"anchored":true,"attempts":1,"ts":"' + (Get-Date).AddMinutes(-60).ToString('yyyy-MM-ddTHH:mm:sszzz', $cxInv) + '"}'
        $cxRun = Invoke-CodexFireInt @{ r5 = $cxR5Run } -Seed $seedClaude
    } catch { $cxRunErr = $_.Exception.Message }
    Test-Case 'codex fire: a running window is not pinged - running, chase booked 2 min after its reset as a Codex no-wake one-shot, toast says when' {
        if (-not $cxRun) { return ('run threw: ' + $cxRunErr) }
        $r = $cxRun; $f = $r.fire
        $end = [DateTimeOffset]::FromUnixTimeSeconds($cxR5Run).LocalDateTime
        $once = @(Get-CxRecs $r 'schedule-once') | Select-Object -First 1
        $at = $null
        if ($once) { $at = ConvertTo-LocalTime $once.fireAt }
        $f -and $f.ok -and ($f.pinged -eq $false) -and ($f.state -eq 'running') -and ($f.anchored -eq $false) -and
            ([string]$f.resets_at -eq $end.ToString('yyyy-MM-dd HH:mm')) -and (Test-CxNoExec $r) -and (Test-CxAllowed $r) -and
            ((@(Get-CxRecs $r 'codex-read') | Select-Object -First 1).src -eq 'pre') -and
            $once -and ([string]$once.label -like 'chase*') -and $at -and ([Math]::Abs(($at - $end.AddMinutes(2)).TotalSeconds) -lt 90) -and
            ($r.reg.Count -eq 1) -and ($r.reg[0].name -like 'ClaudePreheat-Codex-Once-*') -and $r.reg[0].nowake -and
            (($r.reg[0].args -join ' ') -eq ('fire -Provider codex -Job ' + $r.reg[0].name)) -and
            ($r.toast.Count -eq 1) -and ($r.toast[0] -like '*|codex|*')
    }
    Test-Case 'codex fire: proxy + CODEX_HOME from schedule.json reach the child; the env is put back; the cache is atomic, source fire, email masked' {
        if (-not $cxRun) { return ('run threw: ' + $cxRunErr) }
        $cacheF = Join-Path $Tmp 'state-ratelimits-codex.json'
        $raw = ''; $c = $null
        try { $raw = Get-Content $cacheF -Raw -Encoding UTF8; $c = $raw | ConvertFrom-Json } catch { }
        (@($cxRun.calls | Where-Object { $_ -eq ('env https=http://127.0.0.1:9 http=http://127.0.0.1:9 home=' + $cxIntHome + ' rustlog=off') }).Count -ge 1) -and
            ($env:HTTPS_PROXY -ne 'http://127.0.0.1:9') -and ($env:CODEX_HOME -ne $cxIntHome) -and
            $c -and ($c.source -eq 'fire') -and ($c.has5h -eq $true) -and ([long]$c.rate_limits.five_hour.resets_at -eq $cxR5Run) -and
            ($c.account.emailMasked -eq 's***@example.com') -and ($raw -notmatch 'stub\.user@') -and
            (@(Get-ChildItem $Tmp -Filter 'state-ratelimits-codex*').Count -eq 1)
    }

    $cxAnch = $null; $cxAnchErr = ''
    try { $cxAnch = Invoke-CodexFireInt @{ anchor = $true } -Wait 10 } catch { $cxAnchErr = $_.Exception.Message }
    Test-Case 'codex fire: an idle window, a ping that anchors, a frozen read at pre + elapsed -> anchored, tokens and exe kind journaled, nothing booked' {
        if (-not $cxAnch) { return ('run threw: ' + $cxAnchErr) }
        $r = $cxAnch; $f = $r.fire
        $f -and $f.ok -and ($f.pinged -eq $true) -and ($f.state -eq 'anchored') -and ($f.anchored -eq $true) -and ($f.anchor_src -eq 'ratelimit') -and
            $r.state -and ([Math]::Abs([long]$f.resets_epoch - $r.state) -le 3) -and ($f.attempts -eq 1) -and
            ($f.tokens_in -eq 16900) -and ($f.tokens_cached -eq 12000) -and ($f.exe_kind -eq 'env') -and
            (@($r.calls | Where-Object { $_ -like 'exec stdin=*' }).Count -eq 1) -and (Test-CxAllowed $r) -and
            (@(Get-CxRecs $r 'codex-read' | Where-Object { $_.src -eq 'post' }).Count -ge 2) -and
            ($r.reg.Count -eq 0) -and ($r.toast.Count -eq 1)
    }
    $cxSlide = $null; $cxSlideErr = ''
    try { $cxSlide = Invoke-CodexFireInt @{ anchor = $false } -Wait 10 } catch { $cxSlideErr = $_.Exception.Message }
    Test-Case 'codex fire: a ping that starts nothing (reset keeps sliding) -> sliding after the 120s confirm read, nothing booked' {
        if (-not $cxSlide) { return ('run threw: ' + $cxSlideErr) }
        $r = $cxSlide; $f = $r.fire
        $f -and $f.ok -and ($f.pinged -eq $true) -and ($f.state -eq 'sliding') -and ($f.anchored -eq $false) -and
            (@(Get-CxRecs $r 'codex-read' | Where-Object { $_.src -eq 'post' }).Count -eq 3) -and ($r.reg.Count -eq 0)
    }
    Test-Case 'codex fire: an account with no 5h window (free 30d) is never pinged - no5h, toast once, not again on the next no5h' {
        $r1 = Invoke-CodexFireInt @{ profile = 'free30d' }
        $seed = '{"ev":"fire","provider":"codex","ok":false,"kind":"no5h","pinged":false,"state":"no5h","ts":"' + (Get-Date).AddDays(-1).ToString('yyyy-MM-ddTHH:mm:sszzz', $cxInv) + '"}'
        $r2 = Invoke-CodexFireInt @{ profile = 'free30d' } -Seed $seed
        $f = $r1.fire
        $f -and (-not $f.ok) -and ($f.kind -eq 'no5h') -and ($f.pinged -eq $false) -and ($f.state -eq 'no5h') -and (Test-CxNoExec $r1) -and
            ($r1.toast.Count -eq 1) -and $r2.fire -and ($r2.fire.kind -eq 'no5h') -and ($r2.toast.Count -eq 0)
    }
    Test-Case 'codex fire: signed out -> auth, API-key login -> apikey; neither pings' {
        $so = Invoke-CodexFireInt @{ profile = 'signedout' }
        $ak = Invoke-CodexFireInt @{ profile = 'apikey' }
        $so.fire -and (-not $so.fire.ok) -and ($so.fire.kind -eq 'auth') -and (Test-CxNoExec $so) -and
            $ak.fire -and (-not $ak.fire.ok) -and ($ak.fire.kind -eq 'apikey') -and (Test-CxNoExec $ak)
    }
    Test-Case 'codex fire: a usage limit fails once (no retry), says limit, claims no anchor' {
        $r = Invoke-CodexFireInt @{ exec = 'limit' }
        $f = $r.fire
        $f -and (-not $f.ok) -and ($f.kind -eq 'limit') -and ($f.attempts -eq 1) -and (-not (Test-Prop $f 'anchored')) -and
            (@($r.calls | Where-Object { $_ -like 'exec stdin=*' }).Count -eq 1)
    }
    Test-Case 'codex fire: exec says "not logged in" after a signed-in pre-read -> config-mismatch, not a re-login prompt, no retry' {
        $r = Invoke-CodexFireInt @{ exec = 'auth' }
        $f = $r.fire
        $f -and (-not $f.ok) -and ($f.kind -eq 'config-mismatch') -and (@($r.calls | Where-Object { $_ -like 'exec stdin=*' }).Count -eq 1)
    }
    Test-Case 'codex fire: an exec argv the binary refuses fails the fire instead of passing (retried once, after a read)' {
        $r = Invoke-CodexFireInt @{ exec = 'usage' }
        $f = $r.fire
        $f -and (-not $f.ok) -and ([string]$f.kind) -and ($f.anchored -ne $true) -and ($f.attempts -eq 2) -and
            (@(Get-CxRecs $r 'codex-read' | Where-Object { $_.src -eq 'retry' }).Count -eq 1) -and ($f.auth_rot -eq 'none')
    }
    Test-Case 'codex fire: out of time budget -> no retry and no confirm read (the worst case stays bounded)' {
        $CodexFireBudgetSec = 0
        $u = Invoke-CodexFireInt @{ exec = 'usage' }
        $s = Invoke-CodexFireInt @{ anchor = $false } -Wait 10
        $u.fire -and ($u.fire.attempts -eq 1) -and (@(Get-CxRecs $u 'codex-read' | Where-Object { $_.src -eq 'retry' }).Count -eq 0) -and
            $s.fire -and ($s.fire.state -eq 'sliding') -and (@(Get-CxRecs $s 'codex-read' | Where-Object { $_.src -eq 'post' }).Count -eq 2)
    }
    $cxSlidingSeed = @(
        ('{"ev":"fire","provider":"codex","ok":true,"pinged":true,"state":"sliding","anchored":false,"ts":"' + (Get-Date).AddDays(-2).ToString('yyyy-MM-ddTHH:mm:sszzz', $cxInv) + '"}'),
        ('{"ev":"fire","provider":"codex","ok":true,"pinged":true,"state":"sliding","anchored":false,"ts":"' + (Get-Date).AddDays(-1).ToString('yyyy-MM-ddTHH:mm:sszzz', $cxInv) + '"}')
    )
    Test-Case 'codex fire: two sliding pings in a row pause Codex fires (no codex started at all) until the next Codex apply; a Claude apply does not count' {
        $p1 = Invoke-CodexFireInt @{} -Seed ($cxSlidingSeed -join "`n")
        $claudeApply = '{"ev":"apply","tasks":1,"ts":"' + (Get-Date).AddHours(-1).ToString('yyyy-MM-ddTHH:mm:sszzz', $cxInv) + '"}'
        $p2 = Invoke-CodexFireInt @{} -Seed ((@($cxSlidingSeed) + @($claudeApply)) -join "`n")
        $codexApply = '{"ev":"apply","provider":"codex","tasks":1,"ts":"' + (Get-Date).AddHours(-1).ToString('yyyy-MM-ddTHH:mm:sszzz', $cxInv) + '"}'
        $p3 = Invoke-CodexFireInt @{ r5 = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1800) } -Seed ((@($cxSlidingSeed) + @($codexApply)) -join "`n")
        $p1.fire -and (-not $p1.fire.ok) -and ($p1.fire.kind -eq 'paused') -and ($p1.fire.pinged -eq $false) -and ($p1.calls.Count -eq 0) -and ($p1.toast.Count -eq 1) -and
            $p2.fire -and ($p2.fire.kind -eq 'paused') -and
            $p3.fire -and ($p3.fire.kind -ne 'paused') -and ($p3.fire.state -eq 'running')
    }
    Test-Case 'codex fire: PREHEAT_CODEX_FORCE_PING=1 (test switch) gets past the pause' {
        $snapF = Get-CxEnvSnapshot
        try {
            $env:PREHEAT_CODEX_FORCE_PING = '1'
            $r = Invoke-CodexFireInt @{ r5 = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1800) } -Seed ($cxSlidingSeed -join "`n")
        } finally { Restore-CxEnvSnapshot $snapF }
        $r.fire -and ($r.fire.kind -ne 'paused') -and ($r.calls.Count -gt 0)
    }
    Test-Case 'codex fire (macOS path): a Codex follow-up never books another, and the spent one-shot deletes its own plist' {
        $due = (Get-Date).AddMinutes(-1)
        $stampD = $due.ToString('yyyyMMdd-HHmm', $cxInv)
        $self = 'ClaudePreheat-Codex-Once-' + $stampD
        $la = Join-Path $Tmp 'cx-launchagents'
        New-Item -ItemType Directory -Path $la -Force | Out-Null
        $plist = Join-Path $la ('com.claude-preheat.Codex-Once-' + $stampD + '.plist')
        Set-Content -Path $plist -Value 'x' -Encoding ASCII
        $seed = '{"ev":"schedule-once","provider":"codex","fireAt":"' + $due.ToString('s', $cxInv) + '","label":"chase ratelimits","ts":"' + (Get-Date).AddHours(-3).ToString('yyyy-MM-ddTHH:mm:sszzz', $cxInv) + '"}'
        $r = Invoke-CodexFireInt @{ r5 = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 2400) } -Seed $seed -Self $self -MacAgentDir $la
        $skip = @(Get-CxRecs $r 'chase-skip') | Select-Object -First 1
        $r.fire -and ($r.fire.state -eq 'running') -and ($r.reg.Count -eq 0) -and $skip -and ([string]$skip.reason -like '*follow-up*') -and
            (-not (Test-Path $plist))
    }
    Test-Case 'codex fire: a lock held by another live Codex fire is left in place and this fire stands down without starting codex; a fire of our own leaves none' {
        $lock = Join-Path $Tmp 'cx-int.lock'
        ('{"pid":' + $PID + ',"job":"ClaudePreheat-Codex-Once-20990101-0000","startedAt":"' + (Get-Date).ToString('s', $cxInv) + '"}') | Set-Content -Path $lock -Encoding UTF8
        $still = $false
        try { $r = Invoke-CodexFireInt @{ r5 = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1800) } } finally { $still = Test-Path $lock; Remove-Item $lock -ErrorAction SilentlyContinue }
        $own = Invoke-CodexFireInt @{ r5 = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1800) }
        $r.fire -and $still -and ($r.fire.kind -eq 'other') -and ([string]$r.fire.err -like '*another Codex fire*') -and ($r.calls.Count -eq 0) -and
            ($r.toast.Count -eq 0) -and $own.fire -and ($own.fire.kind -ne 'other') -and (-not (Test-Path $lock))
    }

    Write-Host '-- codex: apply / off / locks (scheduler doubled) --'
    function Invoke-ApplyMock([string]$Config, [string]$Provider = 'all', [string]$CodexHomeEnv = '', [switch]$FreshCodexLock, [int]$LockPid = $PID) {
        # Invoke-Apply with the scheduler doubled -> @{ reg; remove; claude; err; recs; config; calls }
        $LogPath       = Join-Path $Tmp ('cx-apply-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.jsonl')
        $ConfigPath    = New-Fixture ('cx-apply-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json') @($Config)
        $StatePath     = Join-Path $Tmp 'cx-apply-state.json'
        $FireLock      = Join-Path $Tmp 'cx-apply-claude.lock'
        $CodexFireLock = Join-Path $Tmp 'cx-apply-codex.lock'
        Remove-Item $FireLock, $CodexFireLock -ErrorAction SilentlyContinue
        if ($FreshCodexLock) { ('{"pid":' + $LockPid + ',"job":"x","startedAt":"2026-01-01T00:00:00"}') | Set-Content -Path $CodexFireLock -Encoding UTF8 }
        $script:AReg = @(); $script:ARemove = @(); $script:AClaude = 0
        function Start-Sleep { param($Seconds, $Milliseconds) }
        function Register-PreheatJob { param([string]$Name, [string[]]$Days, [datetime]$At, [switch]$NoWake, [string[]]$ScriptArgs) $a = @(); if ($ScriptArgs) { $a = @($ScriptArgs) }; $script:AReg += @{ name = $Name; days = @($Days); args = $a } }
        function Remove-PreheatJobs { param([string]$Pattern) $script:ARemove += $Pattern }
        function Remove-StaleOnceJobs { }
        function Resolve-ClaudeExe { param([switch]$NoCache) $script:AClaude++; 'C:\stub\claude.exe' }
        function Test-WakeTimers { }
        function Limit-LaunchdErrLog { }
        # belt and braces: should a double above ever be bypassed, nothing real is touched
        function Register-ScheduledTask { throw 'test: the real Register-ScheduledTask was reached' }
        function Unregister-ScheduledTask { throw 'test: the real Unregister-ScheduledTask was reached' }
        function Get-ScheduledTask { }
        function launchctl { throw 'test: the real launchctl was reached' }
        Set-CodexStub @{}
        $snap = Get-CxEnvSnapshot
        if ($CodexHomeEnv) { $env:CODEX_HOME = $CodexHomeEnv } else { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
        $err = $null
        try { Invoke-Apply -Provider $Provider 6>$null | Out-Null } catch { $err = $_.Exception.Message } finally { Restore-CxEnvSnapshot $snap }
        $cfg = $null
        try { $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        @{ reg = @($script:AReg); remove = @($script:ARemove); claude = $script:AClaude; err = $err; recs = @(Read-JsonLines $LogPath); config = $cfg; calls = @(Get-CodexStubCalls) }
    }
    $cxBoth = '{"_readme":"x","proxy":"http://127.0.0.1:9","chase":false,"extra":{"keep":1},"rules":[{"days":["Mon"],"reset":"08:40"}],"codex":{"rules":[{"days":["Tue"],"reset":"15:00"}],"chase":false}}'
    Test-Case 'apply on an old schedule.json (no codex key): the same Claude task, the same args, one provider-less apply record, codex never spawned' {
        $r = Invoke-ApplyMock '{"rules":[{"days":["Mon"],"reset":"08:40"}]}'
        $applies = @($r.recs | Where-Object { $_.ev -eq 'apply' })
        (-not $r.err) -and ($r.reg.Count -eq 1) -and ($r.reg[0].name -eq 'ClaudePreheat-Wk-0340-Mon') -and
            ((($r.reg[0].args -join ' ') -eq '') -or (($r.reg[0].args -join ' ') -eq 'fire')) -and
            ($r.remove -contains 'ClaudePreheat-Wk*') -and ($applies.Count -eq 1) -and (-not (Test-Prop $applies[0] 'provider')) -and
            ($applies[0].tasks -eq 1) -and ($r.claude -eq 1) -and ($r.calls.Count -eq 0)
    }
    Test-Case 'apply with a codex section: both plans, Codex tasks run fire -Provider codex, one apply record each, still no codex spawned' {
        $r = Invoke-ApplyMock $cxBoth
        $cx = @($r.reg | Where-Object { $_.name -like 'ClaudePreheat-Codex-Wk-*' })
        $cl = @($r.reg | Where-Object { $_.name -like 'ClaudePreheat-Wk-*' })
        $applies = @($r.recs | Where-Object { $_.ev -eq 'apply' })
        (-not $r.err) -and ($cl.Count -eq 1) -and ($cx.Count -eq 1) -and ($cx[0].name -eq 'ClaudePreheat-Codex-Wk-1000-Tue') -and
            (($cx[0].args -join ' ') -eq 'fire -Provider codex') -and
            ($r.remove -contains 'ClaudePreheat-Codex-Wk*') -and ($r.remove -contains 'ClaudePreheat-Wk*') -and
            ($applies.Count -eq 2) -and (@($applies | Where-Object { $_.provider -eq 'codex' }).Count -eq 1) -and ($r.calls.Count -eq 0)
    }
    Test-Case 'apply -Provider codex leaves every Claude task alone and never looks for claude' {
        $r = Invoke-ApplyMock $cxBoth 'codex'
        (-not $r.err) -and (@($r.reg | Where-Object { $_.name -like 'ClaudePreheat-Wk-*' }).Count -eq 0) -and
            (@($r.reg | Where-Object { $_.name -like 'ClaudePreheat-Codex-Wk-*' }).Count -eq 1) -and
            ($r.remove -notcontains 'ClaudePreheat-Wk*') -and ($r.claude -eq 0) -and
            (@($r.recs | Where-Object { ($_.ev -eq 'apply') -and (-not (Test-Prop $_ 'provider')) }).Count -eq 0)
    }
    Test-Case 'apply for a Codex-only user (empty top-level rules) installs Codex without resolving claude' {
        $r = Invoke-ApplyMock '{"rules":[],"codex":{"rules":[{"days":["Wed"],"reset":"12:00"}]}}'
        (-not $r.err) -and ($r.claude -eq 0) -and (@($r.reg | Where-Object { $_.name -eq 'ClaudePreheat-Codex-Wk-0700-Wed' }).Count -eq 1)
    }
    Test-Case 'apply records a changed CODEX_HOME into codex.home and keeps every other key' {
        $h = Join-Path $Tmp 'cx-apply-home'
        $r = Invoke-ApplyMock $cxBoth 'codex' $h
        $c = $r.config
        (-not $r.err) -and $c -and ($c.codex.home -eq $h) -and ($c.proxy -eq 'http://127.0.0.1:9') -and ($c.chase -eq $false) -and
            ($c.extra.keep -eq 1) -and ($c.codex.chase -eq $false) -and (@($c.codex.rules).Count -eq 1) -and ($c.rules[0].reset -eq '08:40')
    }
    Test-Case 'apply: a broken Codex section never stops the Claude plan' {
        $r = Invoke-ApplyMock '{"rules":[{"days":["Mon"],"reset":"08:40"}],"codex":{"rules":[{"days":["Xyz"],"reset":"15:00"}]}}'
        (@($r.reg | Where-Object { $_.name -eq 'ClaudePreheat-Wk-0340-Mon' }).Count -eq 1) -and
            (@($r.reg | Where-Object { $_.name -like 'ClaudePreheat-Codex-*' }).Count -eq 0)
    }
    Test-Case 'apply waits for a running Codex fire too: a live .fire-codex.lock fails the Codex half only, the Claude half still applies' {
        $r = Invoke-ApplyMock $cxBoth 'all' '' -FreshCodexLock
        ([string]$r.err -like '*codex:*running right now*') -and
            (@($r.reg | Where-Object { $_.name -like 'ClaudePreheat-Codex-*' }).Count -eq 0) -and ($r.remove -notcontains 'ClaudePreheat-Codex-Wk*') -and
            (@($r.reg | Where-Object { $_.name -like 'ClaudePreheat-Wk-*' }).Count -eq 1)
    }
    Test-Case 'apply -Provider codex: a Codex lock whose process is gone does not block (a killed fire leaves one behind)' {
        $r = Invoke-ApplyMock $cxBoth 'codex' '' -FreshCodexLock -LockPid ([int]::MaxValue)
        (-not $r.err) -and (@($r.reg | Where-Object { $_.name -like 'ClaudePreheat-Codex-Wk-*' }).Count -eq 1)
    }
    Test-Case 'off / off -Codex: each waits for the lock of what it removes; -Codex removes only Codex tasks' {
        $LogPath = Join-Path $Tmp 'cx-off.jsonl'
        $FireLock = Join-Path $Tmp 'cx-off-claude.lock'
        $CodexFireLock = Join-Path $Tmp 'cx-off-codex.lock'
        Remove-Item $FireLock, $CodexFireLock -ErrorAction SilentlyContinue
        $script:LRemove = @()
        function Start-Sleep { param($Seconds, $Milliseconds) }
        function Remove-PreheatJobs { param([string]$Pattern) $script:LRemove += $Pattern }
        function Unregister-ScheduledTask { throw 'test: the real Unregister-ScheduledTask was reached' }
        function Get-ScheduledTask { }
        function launchctl { throw 'test: the real launchctl was reached' }
        $fresh = '{"pid":' + $PID + ',"job":"x","startedAt":"2026-01-01T00:00:00"}'
        $fresh | Set-Content -Path $CodexFireLock -Encoding UTF8
        $m1 = ''; try { Invoke-Off 6>$null } catch { $m1 = $_.Exception.Message }
        $m2 = ''; try { Invoke-Off -Provider 'codex' 6>$null } catch { $m2 = $_.Exception.Message }
        $m3 = ''; try { Wait-FireLock -MaxSec 1 -Path $CodexFireLock } catch { $m3 = $_.Exception.Message }
        $blocked = $script:LRemove.Count
        Remove-Item $CodexFireLock -ErrorAction SilentlyContinue
        # a running CLAUDE fire does not hold up removing the Codex tasks
        $fresh | Set-Content -Path $FireLock -Encoding UTF8
        $m4 = ''; try { Invoke-Off -Provider 'codex' 6>$null } catch { $m4 = $_.Exception.Message }
        Remove-Item $FireLock -ErrorAction SilentlyContinue
        $codexOnly = @($script:LRemove)
        $script:LRemove = @()
        Invoke-Off 6>$null
        ($m1 -like '*running right now*') -and ($m2 -like '*running right now*') -and ($m3 -like '*running right now*') -and ($blocked -eq 0) -and
            (-not $m4) -and ($codexOnly.Count -eq 1) -and ($codexOnly[0] -eq 'ClaudePreheat-Codex-*') -and ($script:LRemove -contains 'ClaudePreheat*')
    }
    Test-Case 'the one-shot sweep covers Codex one-shots on macOS: spent plist booted out, pending and running kept, orphan Codex label swept, scoped by provider' {
        $OnMac = $true
        $LaunchAgentDir = Join-Path $Tmp 'cx-sweep-la'
        New-Item -ItemType Directory -Path $LaunchAgentDir -Force | Out-Null
        # 20200103 is past due but still running (two one-shots delivered together at wake): kept
        foreach ($n in @('Codex-Once-20200101-0000', 'Codex-Once-20991231-2300', 'Once-20200101-0000', 'Codex-Once-20200103-0000')) {
            Set-Content -Path (Join-Path $LaunchAgentDir ('com.claude-preheat.' + $n + '.plist')) -Value '<plist/>' -Encoding ASCII
        }
        $script:Boot = @()
        function Get-MacUid { '501' }
        function launchctl {
            if (($args[0] -eq 'print') -and ([string]$args[1] -match 'Codex-Once-2020010[34]')) { return 'state = running' }
            if ($args[0] -eq 'print') { return 'services = { com.claude-preheat.Codex-Once-20200102-0000 com.claude-preheat.Codex-Once-20991231-2300 com.claude-preheat.Codex-Once-20200104-0000 }' }
            if ($args[0] -eq 'bootout') { $script:Boot += [string]$args[1] }
        }
        function Unregister-ScheduledTask { throw 'test: the real Unregister-ScheduledTask was reached' }
        function Get-ScheduledTask { }
        $snapS = Get-CxEnvSnapshot
        $claudeKept = $false
        try {
            Remove-Item Env:CLAUDE_PREHEAT_SELF -ErrorAction SilentlyContinue
            # a Codex-scoped sweep (Codex fire / apply -Provider codex) never touches a Claude one-shot
            Remove-StaleOnceJobs 'codex'
            $claudeKept = Test-Path (Join-Path $LaunchAgentDir 'com.claude-preheat.Once-20200101-0000.plist')
            Remove-StaleOnceJobs
        } finally { Restore-CxEnvSnapshot $snapS }
        $claudeKept -and (Test-Path (Join-Path $LaunchAgentDir 'com.claude-preheat.Codex-Once-20200103-0000.plist')) -and
            (@($script:Boot | Where-Object { $_ -like '*Codex-Once-20200103-0000' -or $_ -like '*Codex-Once-20200104-0000' }).Count -eq 0) -and
            (-not (Test-Path (Join-Path $LaunchAgentDir 'com.claude-preheat.Codex-Once-20200101-0000.plist'))) -and
            (Test-Path (Join-Path $LaunchAgentDir 'com.claude-preheat.Codex-Once-20991231-2300.plist')) -and
            (-not (Test-Path (Join-Path $LaunchAgentDir 'com.claude-preheat.Once-20200101-0000.plist'))) -and
            (@($script:Boot | Where-Object { $_ -like '*com.claude-preheat.Codex-Once-20200102-0000' }).Count -ge 1) -and
            (@($script:Boot | Where-Object { $_ -like '*Codex-Once-20991231-2300' }).Count -eq 0)
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
    Clear-TestProxy
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
        # an EMPTY rule set is valid since Codex support (Codex-only users) and
        # would rewrite this checkout's schedule.json and re-register the real
        # tasks - it is exercised only against the throwaway panel root below
        $o = @{ Origin = "http://localhost:$panelPort" }
        $noDay = Invoke-PanelPost '/api/preheat/apply' '{"rules":[{"days":[],"reset":"09:00"}]}' $o 'application/json'
        $badHr = Invoke-PanelPost '/api/preheat/apply' '{"rules":[{"days":["Mon"],"reset":"25:00"}]}' $o 'application/json'
        # the stale baseMtime is the safety net: even a panel that forgot to check
        # the provider must stop at the lock, never write the real schedule
        $badPv = Invoke-PanelPost '/api/preheat/apply' '{"provider":"gemini","rules":[{"days":["Mon"],"reset":"09:00"}],"baseMtime":"1"}' $o 'application/json'
        ($noDay.Code -eq 400) -and ($badHr.Code -eq 400) -and ($badPv.Code -eq 400)
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

# ------------------------------------------- Codex: throwaway preheat root
# A copy of the product in the temp dir with its own schedule.json, journal
# and caches: the CLI runs there as a child process (status/report -Codex
# exactly as typed), and a second panel serves it. Its preheat.ps1 is a
# stand-in that RECORDS every scheduler-touching command (apply, at, +Nh...)
# instead of running it, and hands status/report/learn to the real script -
# so a panel save can be tested for real without registering a single task.
Write-Host ''
Write-Host '-- codex: CLI + panel in a throwaway preheat root (stub codex) --'
$cxRoot = Join-Path $Tmp 'cxroot'
New-Item -ItemType Directory -Path (Join-Path $cxRoot 'web') -Force | Out-Null
foreach ($f in @('panel.ps1', 'platform.ps1', 'codex.ps1', 'mcp-empty.json', 'run-hidden.vbs')) {
    if (Test-Path (Join-Path $Repo $f)) { Copy-Item (Join-Path $Repo $f) $cxRoot -Force }
}
Copy-Item (Join-Path $Repo (Join-Path 'web' 'index.html')) (Join-Path $cxRoot 'web') -Force
Copy-Item (Join-Path $Repo 'preheat.ps1') (Join-Path $cxRoot 'preheat-real.ps1') -Force
$cxBackendLog = Join-Path $cxRoot 'backend-calls.txt'
Set-Content -Path (Join-Path $cxRoot 'preheat.ps1') -Encoding ASCII -Value @(
    '# self-test stand-in (see test.ps1): records scheduler-touching commands, runs read-only ones',
    '$wrapReal = Join-Path $PSScriptRoot ''preheat-real.ps1''',
    'if (($args.Count -ge 1) -and ($args[0] -eq ''__selftest__'')) { . $wrapReal ''__selftest__''; return }',
    'Add-Content -Path (Join-Path $PSScriptRoot ''backend-calls.txt'') -Value ($args -join '' '') -Encoding ASCII',
    'if (($args.Count -ge 1) -and (@(''status'', ''report'', ''learn'') -contains $args[0])) {',
    '    & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $wrapReal @args',
    '    exit $LASTEXITCODE',
    '}',
    'exit 0')
$cxRootHome = Join-Path $cxRoot 'codex-home'
New-Item -ItemType Directory -Path $cxRootHome -Force | Out-Null
$cxRootSched = '{"_readme":"x","proxy":"","chase":true,"extra":{"keep":1},"rules":[{"days":["Mon"],"reset":"10:00"}],' +
    '"codex":{"rules":[{"days":["Tue"],"reset":"15:00"}],"chase":false,"home":' + (ConvertTo-Json -InputObject $cxRootHome) + '}}'
[System.IO.File]::WriteAllText((Join-Path $cxRoot 'schedule.json'), $cxRootSched, (New-Object System.Text.UTF8Encoding($false)))
# the anchored Codex fire 1h ago whose window resets in 4h: the rolling check compares against it
$cxRootR5 = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 4 * 3600
$cxHomeP  = [Environment]::GetFolderPath('UserProfile')
$cxUser   = [Environment]::UserName
$cxTs = { param([int]$Min) (Get-Date).AddMinutes($Min).ToString('yyyy-MM-ddTHH:mm:sszzz', $cxInv) }
@(
    ('{"ev":"fire","ok":true,"anchored":true,"attempts":1,"ts":"' + (& $cxTs -300) + '"}'),
    ('{"ev":"fire","provider":"codex","ok":false,"kind":"other","pinged":false,"state":"unknown","attempts":1,"err":' +
        (ConvertTo-Json -InputObject ('spawn failed in ' + $cxHomeP + '\.codex for stub.user@example.com as ' + $cxUser)) + ',"ts":"' + (& $cxTs -120) + '"}'),
    ('{"ev":"fire","provider":"codex","ok":true,"pinged":true,"state":"anchored","anchored":true,"anchor_src":"ratelimit","plan":"plus","resets_epoch":' + $cxRootR5 +
        ',"resets_at":"' + [DateTimeOffset]::FromUnixTimeSeconds($cxRootR5).LocalDateTime.ToString('yyyy-MM-dd HH:mm', $cxInv) + '","attempts":1,"tokens_in":16900,"ts":"' + (& $cxTs -60) + '"}')
) | Set-Content -Path (Join-Path $cxRoot 'preheat-log.jsonl') -Encoding UTF8

function Invoke-CxCli([string[]]$CliArgs) {
    # the real preheat.ps1 of the throwaway root, as a child process -> @{ code; out }
    $ErrorActionPreference = 'Continue'   # 5.1: a native stderr line under 2>&1 must not throw
    $out = & $cxShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $cxRoot 'preheat-real.ps1') @CliArgs 2>&1 | Out-String
    @{ code = $LASTEXITCODE; out = $out }
}
function Get-CxRootRecs([string]$Ev) { @(Read-JsonLines (Join-Path $cxRoot 'preheat-log.jsonl') | Where-Object { ($_.ev -eq $Ev) -and ($_.provider -eq 'codex') }) }

Test-Case 'status -Codex: a live read through the stub - masked account, plan, the 5h window, rolling check says unchanged, cache + codex-read written' {
    Set-CodexStub @{ r5 = $cxRootR5 }
    $before = @(Get-CxRootRecs 'codex-read').Count
    $o = Invoke-CxCli @('status', '-Codex')
    $reads = @(Get-CxRootRecs 'codex-read')
    $cache = $null
    try { $cache = Get-Content (Join-Path $cxRoot 'state-ratelimits-codex.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    ($o.code -eq 0) -and $o.out.Contains('s***@example.com') -and (-not $o.out.Contains('stub.user@')) -and ($o.out -match 'plus') -and
        ($o.out -match 'reset unchanged') -and ($reads.Count -eq $before + 1) -and ($reads[-1].src -eq 'status') -and
        $cache -and ($cache.source -eq 'status') -and (Test-CodexAllowList)
}
Test-Case 'status -Codex: a reset that moved later than the anchored fire recorded is reported as rolling, with drift_s on the codex-read' {
    Set-CodexStub @{ r5 = ($cxRootR5 + 900) }
    $o = Invoke-CxCli @('status', '-Codex')
    $last = @(Get-CxRootRecs 'codex-read') | Select-Object -Last 1
    ($o.code -eq 0) -and ($o.out -match 'moved later') -and $last -and (Test-Prop $last 'drift_s') -and ([long]$last.drift_s -ge 840)
}
Test-Case 'status -Codex -Json: the cache object plus installed / exeKind / version / signedIn' {
    Set-CodexStub @{ r5 = $cxRootR5 }
    $o = Invoke-CxCli @('status', '-Codex', '-Json')
    $j = $null
    try { $j = $o.out | ConvertFrom-Json } catch { }
    ($o.code -eq 0) -and $j -and ($j.installed -eq $true) -and ($j.exeKind -eq 'env') -and ([string]$j.version -like '*0.99.0*') -and
        ($j.signedIn -eq $true) -and ($j.has5h -eq $true) -and ($j.source -eq 'status')
}
Test-Case 'report -Codex: paste-back text with no email, home path or user name in any spelling' {
    Set-CodexStub @{ r5 = $cxRootR5 }
    $o = Invoke-CxCli @('report', '-Codex')
    $ok = ($o.code -eq 0) -and ($o.out -match '(?i)codex') -and ($o.out -match 'anchored') -and
        ($o.out -notmatch 'stub\.user@') -and (-not $o.out.Contains($cxHomeP)) -and (-not $o.out.Contains(($cxHomeP -replace '\\', '/'))) -and
        (-not $o.out.Contains(($cxHomeP -replace '\\', '\\')))
    # an all-digit user name stays as a bare word (it is a number) - never as a path segment
    if (($cxUser.Length -ge 4) -and ($cxUser -notmatch '^\d+$')) { $ok = $ok -and ($o.out -notmatch ('\b' + [regex]::Escape($cxUser) + '\b')) }
    $ok = $ok -and ($o.out -notmatch ('[\\/]' + [regex]::Escape($cxUser) + '[\\/]'))
    $ok
}
Test-Case 'report without -Codex prints a usage hint; learn -Codex says Claude-only and exits 0; a bad -Provider is a usage error' {
    $r = Invoke-CxCli @('report')
    $l = Invoke-CxCli @('learn', '-Codex')
    $b = Invoke-CxCli @('status', '-Provider', 'gemini')
    ($r.out -match 'report -Codex') -and ($l.code -eq 0) -and ($l.out -match 'Claude-only') -and
        (($b.code -ne 0) -or ($b.out -match 'usage'))
}
Test-Case 'status / status -Json with a codex section: a codex block, every task tagged with its provider, lastActivity kept' {
    $s = Invoke-CxCli @('status')
    $o = Invoke-CxCli @('status', '-Json')
    $j = $null
    try { $j = $o.out | ConvertFrom-Json } catch { }
    $tagged = $true
    if ($j) { foreach ($t in @($j.tasks)) { if (@('claude', 'codex') -notcontains [string]$t.provider) { $tagged = $false } } }
    ($s.code -eq 0) -and ($s.out -match '(?i)codex') -and $j -and $tagged -and ($null -ne $j.PSObject.Properties['lastActivity']) -and
        $j.codex -and ($j.codex.configured -eq $true) -and ($null -ne $j.codex.PSObject.Properties['tasks'])
}

$cxPanelPort = 7880
$cxPanelProc = $null
try {
    $shell = $env:PREHEAT_TEST_SHELL
    if ($shell -ne 'powershell' -and $shell -ne 'pwsh') {
        $shell = 'pwsh'
        if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) { $shell = 'powershell' }
    }
    $spArgs = @{
        FilePath = $shell; PassThru = $true
        ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $cxRoot 'panel.ps1'), '-Port', $cxPanelPort, '-NoBrowser')
    }
    if ($cxOnWin) { $spArgs.WindowStyle = 'Hidden' }
    $env:PREHEAT_PANEL_LOG = Join-Path $Tmp 'panel-cx-log.txt'
    Set-CodexStub @{ profile = 'free30d' }
    Clear-TestProxy
    $cxPanelProc = Start-Process @spArgs
    Remove-Item Env:PREHEAT_PANEL_LOG -ErrorAction SilentlyContinue
    $cxBase = "http://localhost:$cxPanelPort"
    $cxOrigin = @{ Origin = "http://localhost:$cxPanelPort" }
    $cxUp = $false
    for ($i = 0; $i -lt 25 -and -not $cxUp; $i++) {
        Start-Sleep -Milliseconds 700
        try { $null = Invoke-WebRequest -Uri "$cxBase/api/status" -UseBasicParsing -TimeoutSec 5; $cxUp = $true } catch { }
    }
    function Get-CxJson([string]$path) { (Invoke-WebRequest -Uri ($cxBase + $path) -UseBasicParsing -TimeoutSec 30).Content | ConvertFrom-Json }
    function Invoke-CxPost([string]$path, [string]$body, [int]$TimeoutSec = 30) {
        try {
            $r = Invoke-WebRequest -Uri ($cxBase + $path) -Method POST -Body $body -ContentType 'application/json' -Headers $cxOrigin -UseBasicParsing -TimeoutSec $TimeoutSec
            return @{ Code = $r.StatusCode; Body = $r.Content }
        } catch {
            $code = 0
            if ($_.Exception.Response) { $code = $_.Exception.Response.StatusCode.value__ }
            return @{ Code = $code; Body = ''; Err = $_.Exception.Message }
        }
    }
    function Get-CxRootConfig { Get-Content (Join-Path $cxRoot 'schedule.json') -Raw -Encoding UTF8 | ConvertFrom-Json }

    Test-Case 'codex panel comes up on the throwaway root' { $cxUp }
    Test-Case 'GET /api/status: codex installed (the stub, kind env) without spawning it; every task carries its provider' {
        $before = @(Get-CodexStubCalls | Where-Object { $_ -like 'start *' }).Count
        $s = Get-CxJson '/api/status'
        $tagged = $true
        foreach ($t in @($s.preheat.tasks)) { if (@('claude', 'codex') -notcontains [string]$t.provider) { $tagged = $false } }
        $s.codex -and ($s.codex.installed -eq $true) -and ($s.codex.exeKind -eq 'env') -and $tagged -and
            (@(Get-CodexStubCalls | Where-Object { $_ -like 'start *' }).Count -eq $before)
    }
    Test-Case 'GET /api/schedule?provider=: each section its own rules and its own token; no provider = Claude' {
        $cl = Get-CxJson '/api/schedule'
        $cx = Get-CxJson '/api/schedule?provider=codex'
        ($cl.rules[0].days[0] -eq 'Mon') -and ($cx.rules[0].days[0] -eq 'Tue') -and $cl.mtime -and $cx.mtime -and
            ($null -eq $cx.PSObject.Properties['proxy'])
    }
    Test-Case 'POST apply: the token is per section - a Codex save does not 409 a Claude save; each writes only its own section, keeps every other key' {
        $cl0 = Get-CxJson '/api/schedule'
        $cx0 = Get-CxJson '/api/schedule?provider=codex'
        Remove-Item $cxBackendLog -ErrorAction SilentlyContinue
        Set-CodexStub @{ profile = 'free30d' }
        # free30d: no 5h window readable - the save is NOT refused for that
        $a = Invoke-CxPost '/api/preheat/apply' ('{"provider":"codex","rules":[{"days":["Wed"],"reset":"16:00"}],"baseMtime":' + (ConvertTo-Json -InputObject ([string]$cx0.mtime)) + '}')
        $b = Invoke-CxPost '/api/preheat/apply' ('{"rules":[{"days":["Thu"],"reset":"14:00"}],"baseMtime":' + (ConvertTo-Json -InputObject ([string]$cl0.mtime)) + '}')
        $c = Get-CxRootConfig
        $calls = @()
        if (Test-Path $cxBackendLog) { $calls = @(Get-Content $cxBackendLog) }
        ($a.Code -eq 200) -and ($b.Code -eq 200) -and
            ($c.rules[0].days[0] -eq 'Thu') -and ($c.rules[0].reset -eq '14:00') -and
            ($c.codex.rules[0].days[0] -eq 'Wed') -and ($c.codex.chase -eq $false) -and ($c.codex.home -eq $cxRootHome) -and
            ($c.extra.keep -eq 1) -and ($c.proxy -eq '') -and ($c.chase -eq $true) -and
            ($calls -contains 'apply -Provider codex') -and ($calls -contains 'apply -Provider claude') -and
            (@(Get-CodexStubCalls | Where-Object { $_ -like 'start *' }).Count -eq 0)
    }
    Test-Case 'POST apply: a stale Codex token -> 409, an unknown provider -> 400, an empty Codex rule set is allowed' {
        $cx0 = Get-CxJson '/api/schedule?provider=codex'
        $stale = Invoke-CxPost '/api/preheat/apply' '{"provider":"codex","rules":[{"days":["Fri"],"reset":"16:00"}],"baseMtime":"1"}'
        $bad   = Invoke-CxPost '/api/preheat/apply' '{"provider":"gemini","rules":[{"days":["Fri"],"reset":"16:00"}],"baseMtime":"1"}'
        $empty = Invoke-CxPost '/api/preheat/apply' ('{"provider":"codex","rules":[],"baseMtime":' + (ConvertTo-Json -InputObject ([string]$cx0.mtime)) + '}')
        $c = Get-CxRootConfig
        ($stale.Code -eq 409) -and ($bad.Code -eq 400) -and ($empty.Code -eq 200) -and (@($c.codex.rules).Count -eq 0) -and
            ($c.rules[0].days[0] -eq 'Thu')
    }
    Test-Case 'POST apply (Codex) on a schedule.json that does not parse -> 409 and the file untouched; while a Codex fire runs -> 409 busy' {
        $sf = Join-Path $cxRoot 'schedule.json'
        $keep = [System.IO.File]::ReadAllText($sf)
        $lk = Join-Path $cxRoot '.fire-codex.lock'
        $broken = '{"rules": [ {"days": ["Thu"], "reset": "14:00" '
        try {
            [System.IO.File]::WriteAllText($sf, $broken)
            $u = Invoke-CxPost '/api/preheat/apply' '{"provider":"codex","rules":[{"days":["Fri"],"reset":"16:00"}]}'
            $after = [System.IO.File]::ReadAllText($sf)
            [System.IO.File]::WriteAllText($sf, $keep)
            ('{"pid":' + $PID + ',"job":"x","startedAt":"2026-01-01T00:00:00"}') | Set-Content -Path $lk -Encoding UTF8
            $probe = '$p = ''' + $lk + '''; $l = Get-Content $p -Raw | ConvertFrom-Json; $gp = Get-Process -Id ([int]$l.pid) -ErrorAction SilentlyContinue; $e = $null; try { $null = [System.Diagnostics.Process]::GetProcessById([int]$l.pid) } catch { $e = $_.Exception.Message }; ''child: pid={0} gp={1} gpbid_err={2} lwt={3:o} now={4:o} fresh={5}'' -f $l.pid, [bool]$gp, $e, (Get-Item $p).LastWriteTime, (Get-Date), ((Get-Item $p).LastWriteTime -gt (Get-Date).AddMinutes(-20))'
            Write-Host ('  debug: ' + ((& $cxShell -NoProfile -Command $probe 2>&1) | Out-String).Trim())
            $b = Invoke-CxPost '/api/preheat/apply' '{"provider":"codex","rules":[{"days":["Fri"],"reset":"16:00"}]}'
        } finally {
            [System.IO.File]::WriteAllText($sf, $keep)
            Remove-Item $lk -ErrorAction SilentlyContinue
        }
        $ok = ($u.Code -eq 409) -and ($after -eq $broken) -and ($b.Code -eq 409) -and ([System.IO.File]::ReadAllText($sf) -eq $keep)
        if (-not $ok) { Write-Host ('  debug: unparseable={0} untouched={1} busy={2} busyErr={3} pid={4} alive={5}' -f $u.Code, ($after -eq $broken), $b.Code, $b.Err, $PID, [bool](Get-Process -Id $PID -ErrorAction SilentlyContinue)) }
        $ok
    }
    Test-Case 'POST once with provider codex hands -Codex to the backend' {
        Remove-Item $cxBackendLog -ErrorAction SilentlyContinue
        $r = Invoke-CxPost '/api/preheat/once' '{"kind":"plus","value":"2h","provider":"codex"}'
        $calls = @()
        if (Test-Path $cxBackendLog) { $calls = @(Get-Content $cxBackendLog) }
        ($r.Code -eq 200) -and ($calls.Count -eq 1) -and ($calls[0] -match '(^| )\+2h( |$)') -and ($calls[0] -match '(^| )-Codex( |$)')
    }
    Test-Case 'GET /api/ratelimits?provider=codex: the Codex cache verbatim, {} without one' {
        $cf = Join-Path $cxRoot 'state-ratelimits-codex.json'
        Remove-Item $cf -ErrorAction SilentlyContinue
        $none = (Invoke-WebRequest -Uri "$cxBase/api/ratelimits?provider=codex" -UseBasicParsing -TimeoutSec 15).Content
        [System.IO.File]::WriteAllText($cf, '{"capturedAt":"2026-10-26T00:00:00Z","source":"fixture","has5h":false}', (New-Object System.Text.UTF8Encoding($false)))
        $some = (Invoke-WebRequest -Uri "$cxBase/api/ratelimits?provider=codex" -UseBasicParsing -TimeoutSec 15).Content | ConvertFrom-Json
        ($none.Trim() -match '^\{\s*\}$') -and ($some.source -eq 'fixture') -and ($some.has5h -eq $false)
    }
    Test-Case 'GET /api/events?provider=: Codex fires on the Codex tab only, the Claude list unchanged' {
        $cx = @((Get-CxJson '/api/events?provider=codex').events)
        $cl = @((Get-CxJson '/api/events').events)
        ($cx.Count -ge 2) -and (@($cx | Where-Object { $_.provider -ne 'codex' }).Count -eq 0) -and
            ($cl.Count -eq 1) -and (@($cl | Where-Object { $_.provider -eq 'codex' }).Count -eq 0)
    }
    Test-Case 'GET /api/learn?provider=codex answers {unsupported:true}' {
        (Get-CxJson '/api/learn?provider=codex').unsupported -eq $true
    }
    Test-Case 'POST /api/codex/refresh: 409 while a Codex fire holds the lock; otherwise one status -Codex -Json through the stub, allow-list only' {
        $lock = Join-Path $cxRoot '.fire-codex.lock'
        ('{"pid":' + $PID + ',"job":"x","startedAt":"' + (Get-Date).ToString('s', $cxInv) + '"}') | Set-Content -Path $lock -Encoding UTF8
        $busy = Invoke-CxPost '/api/codex/refresh' '{}'
        if ($busy.Code -ne 409) { Write-Host ('  debug: refresh-busy={0} err={1} lock={2}' -f $busy.Code, $busy.Err, (Get-Content $lock -Raw)) }
        Remove-Item $lock -ErrorAction SilentlyContinue
        Set-CodexStub @{ profile = 'free30d' }
        $r = Invoke-CxPost '/api/codex/refresh' '{}' 90
        $j = $null
        try { $j = $r.Body | ConvertFrom-Json } catch { }
        ($busy.Code -eq 409) -and ($r.Code -eq 200) -and $j -and ($j.installed -eq $true) -and ($j.has5h -eq $false) -and
            (@(Get-CodexStubCalls | Where-Object { $_ -like 'rpc account/rateLimits/read*' }).Count -ge 1) -and (Test-CodexAllowList) -and
            (@(Get-CodexStubCalls | Where-Object { $_ -like 'exec *' }).Count -eq 0)
    }
} finally {
    if ($cxPanelProc) { try { Stop-Process -Id $cxPanelProc.Id -Force -ErrorAction SilentlyContinue } catch { } }
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
Test-Case 'fire history shows the reset time the fire measured, falling back to fire + 5h' {
    $h = Get-Content (Join-Path $Repo 'web\index.html') -Raw -Encoding UTF8
    $h -match 'e\.resets_at \? parseDate\(e\.resets_at\)'
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
    foreach ($f in @('preheat.ps1', 'platform.ps1', 'codex.ps1')) {
        $c = Get-Content (Join-Path $Repo $f) -Raw -Encoding UTF8
        $all = ([regex]::Matches($c, 'ParseExact')).Count
        $pinned = ([regex]::Matches($c, 'ParseExact\([^\r\n]*InvariantCulture')).Count
        # codex.ps1 works in epoch seconds and may have no ParseExact at all
        if ((($all -lt 1) -and ($f -ne 'codex.ps1')) -or ($all -ne $pinned)) { $ok = $false }
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
    # it lives in platform.ps1 since Codex support (the codex ping quotes with it too)
    $p = (Get-Content (Join-Path $Repo 'panel.ps1') -Raw -Encoding UTF8) + (Get-Content (Join-Path $Repo 'platform.ps1') -Raw -Encoding UTF8)
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
    foreach ($f in @('preheat.ps1', 'panel.ps1', 'platform.ps1', 'install.ps1', 'test.ps1', 'codex.ps1')) {
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
    # codex.ps1 judges the exec exit code the same way (its variable may differ)
    $cx = Get-Content (Join-Path $Repo 'codex.ps1') -Raw -Encoding UTF8
    if (([regex]::Matches($cx, '\$null = \$\w+\.Handle')).Count -lt 1) { $ok = $false }
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
    foreach ($f in @('preheat.ps1', 'panel.ps1', 'platform.ps1', 'install.ps1', 'test.ps1', 'codex.ps1', (Join-Path '.github' (Join-Path 'workflows' 'stub-codex.ps1')))) {
        try { $null = [scriptblock]::Create((Get-Content (Join-Path $Repo $f) -Raw)) } catch { $ok = $false }
    }
    $ok
}
Test-Case 'no PowerShell 7-only syntax (project claims 5.1 support)' {
    $ok = $true
    foreach ($f in @('preheat.ps1', 'panel.ps1', 'platform.ps1', 'install.ps1', 'codex.ps1', (Join-Path '.github' (Join-Path 'workflows' 'stub-codex.ps1')))) {
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
        'launchd-err.log', 'claude-ignite-promo', '.fire.lock',
        '.fire-codex.lock', 'state-ratelimits-codex.json', 'firepit-codex')
    $ok = $true
    foreach ($p in $ignored) {
        git -C $Repo check-ignore $p 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { $ok = $false }
    }
    $ok
}
$cxProductPs1 = @('preheat.ps1', 'panel.ps1', 'platform.ps1', 'install.ps1', 'codex.ps1')
Test-Case 'every product .ps1/.vbs/.cjs is pure ASCII after the BOM (5.1 reads a BOM-less byte >= 0x80 through the ANSI code page)' {
    # web/index.html is exempt: it carries the Chinese strings on purpose
    $files = @(Get-ChildItem -Path $Repo -Filter '*.ps1' | ForEach-Object { $_.FullName }) +
        @((Join-Path $Repo 'run-hidden.vbs'), (Join-Path $Repo 'statusline-tap.cjs')) +
        @(Get-ChildItem -Path (Join-Path $Repo (Join-Path '.github' 'workflows')) -Filter '*.ps1' | ForEach-Object { $_.FullName })
    $bad = @()
    foreach ($f in $files) {
        if (-not (Test-Path $f)) { continue }
        $b = [System.IO.File]::ReadAllBytes($f)
        $start = 0
        if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $start = 3 }
        for ($i = $start; $i -lt $b.Length; $i++) { if ($b[$i] -ge 0x80) { $bad += (Split-Path $f -Leaf); break } }
    }
    if ($bad.Count -gt 0) { return ('non-ASCII in: ' + ($bad -join ', ')) }
    $true
}
Test-Case 'no PowerShell 7-only runtime API in product scripts (ArgumentList, Kill($true), StandardInputEncoding, -AsHashtable, bare $IsWindows)' {
    # the syntax guard above cannot see these: they parse fine on 5.1 and
    # only throw when the line runs - inside a scheduled fire nobody watches
    $bad = @()
    foreach ($f in @($cxProductPs1) + @((Join-Path '.github' (Join-Path 'workflows' 'stub-codex.ps1')))) {
        $n = 0
        foreach ($line in @(Get-Content (Join-Path $Repo $f) -Encoding UTF8)) {
            $n++
            $t = $line.Trim()
            if ($t.StartsWith('#')) { continue }
            if (($t -match '\.ArgumentList\b') -or ($t -match 'Kill\(\s*\$true\s*\)') -or ($t -match 'StandardInputEncoding') -or
                ($t -match '-AsHashtable') -or ($t -match 'ConvertFrom-Json[^|;]*-Depth') -or ($t -match '-Encoding\s+utf8NoBOM') -or
                (($t -match '\$Is(Windows|MacOS|Linux)\b') -and ($t -notmatch '\btry\b'))) { $bad += ('{0}:{1}' -f $f, $n) }
        }
    }
    if ($bad.Count -gt 0) { return ('7-only API at ' + ($bad -join ', ')) }
    $true
}
Test-Case 'the codex RPC allow-list holds exactly the four read-only methods (no reset-credit consume, no usage/model calls)' {
    $c = Get-Content (Join-Path $Repo 'codex.ps1') -Raw -Encoding UTF8
    $m = [regex]::Match($c, "@\(([^)]*'account/rateLimits/read'[^)]*)\)")
    if (-not $m.Success) { return 'no @(...) allow-list naming account/rateLimits/read found in codex.ps1' }
    $items = @([regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    ($items.Count -eq 4) -and ($items -contains 'initialize') -and ($items -contains 'initialized') -and
        ($items -contains 'account/read') -and ($items -contains 'account/rateLimits/read') -and
        ($m.Groups[1].Value -notmatch 'consume|usage/read|model/list')
}
Test-Case 'the codex exec argv in source is the safe ping: ephemeral, read-only sandbox, user config/rules ignored, features off, no escalation flag' {
    $c = Get-Content (Join-Path $Repo 'codex.ps1') -Raw -Encoding UTF8
    $ok = $c.Contains('--ephemeral') -and $c.Contains('--ignore-user-config') -and $c.Contains('--ignore-rules') -and
        $c.Contains('--skip-git-repo-check') -and ($c -match "'-s'\s*,\s*'read-only'|-s read-only") -and
        $c.Contains('features.hooks=false') -and $c.Contains('features.plugins=false') -and $c.Contains('Reply with exactly: hi')
    foreach ($f in @('hooks', 'memories', 'goals', 'apps', 'plugins')) { $ok = $ok -and $c.Contains('features.' + $f + '=false') }
    # no model, effort or profile pinned: the account's default meters the bucket the user works in
    $ok -and ($c -notmatch '--dangerously-bypass|--full-auto|--yolo|danger-full-access|workspace-write') -and
        ($c -notmatch "'-m'|`"-m`"|--model|--profile|--oss|model_reasoning_effort")
}
Test-Case 'no product line reads auth.json (Test-Path and the mtime only)' {
    $bad = @()
    foreach ($f in $cxProductPs1) {
        foreach ($line in @(Get-Content (Join-Path $Repo $f) -Encoding UTF8)) {
            if (($line -match 'auth\.json') -and ($line -match 'Get-Content|ReadAll|Copy-Item|OpenRead|Import-|ConvertFrom-Json|\[System\.IO\.File\]::Open')) { $bad += $f }
        }
    }
    $bad.Count -eq 0
}
Test-Case 'the macOS stale-once sweep and the e2e sweep both cover Codex labels' {
    $p = Get-Content (Join-Path $Repo 'platform.ps1') -Raw -Encoding UTF8
    $e = Get-Content (Join-Path $Repo (Join-Path '.github' (Join-Path 'workflows' 'e2e-mac.ps1'))) -Raw -Encoding UTF8
    $p.Contains("`$labelRe += 'Codex-'") -and $p.Contains(")Once-\d{8}-\d{4}')") -and $e.Contains('com\.claude-preheat\.[A-Za-z0-9-]+') -and $e.Contains('-Codex')
}
Test-Case 'panel page: Claude | Codex tabs remembered, provider on every call, Refresh wired, the no-5h-window banner in both languages' {
    $h = Get-Content (Join-Path $Repo (Join-Path 'web' 'index.html')) -Raw -Encoding UTF8
    $cut = $h.IndexOf('  en: {')
    if ($cut -lt 0) { return $false }
    $zh = $h.Substring(0, $cut); $en = $h.Substring($cut)
    # 'du bu dao 5 xiao shi e du chuang' by code point: this file stays pure ASCII
    $no5h = (-join ([char[]]@(0x8BFB, 0x4E0D, 0x5230))) + ' 5 ' + (-join ([char[]]@(0x5C0F, 0x65F6, 0x989D, 0x5EA6, 0x7A97)))
    ($h -match 'clr_provider') -and ($h -match '/api/codex/refresh') -and ($h -match 'provider=') -and
        $zh.Contains($no5h) -and ($en -match '(?i)\bno\b[^"''\n]{0,40}5[- ]?h(our)?\b[^"''\n]{0,20}window')
}

# ----------------------------------------------------------------- summary
foreach ($n in $cxEnvPrev.Keys) {
    if ($null -eq $cxEnvPrev[$n]) { Remove-Item ('Env:' + $n) -ErrorAction SilentlyContinue }
    else { [Environment]::SetEnvironmentVariable($n, $cxEnvPrev[$n]) }
}
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
