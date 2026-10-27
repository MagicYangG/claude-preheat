#Requires -Version 7.0
# macOS end-to-end: schedule -> launchd fires -> pwsh fire -> (stubbed) claude
# -> journal -> clean removal. It registers a REAL user LaunchAgent and removes
# it again; the only unstubbed piece of the chain is the claude binary itself
# (needs a real subscription - beta testers cover that).
#
# The CI gate is doubled on purpose. The cleanup runs `preheat off`, which
# removes EVERY ClaudePreheat job, so a stray CI=true exported in someone's
# shell must not be enough to wipe their real schedule; RUNNER_TEMP exists only
# on a GitHub runner. On top of that the whole run lives in a throwaway HOME,
# so the plists it writes never share a directory with a real schedule, and it
# refuses outright on a machine that already carries preheat agents.
$ErrorActionPreference = 'Stop'
# launchctl print / id are queried for their text, not their exit code - on
# PowerShell 7.4+ a non-zero native exit must not become a terminating error
$PSNativeCommandUseErrorActionPreference = $false
if ($env:GITHUB_ACTIONS -ne 'true' -or -not $env:RUNNER_TEMP) {
    throw 'CI-only: this script registers real LaunchAgents and wipes the whole preheat schedule at the end'
}
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Set-Location $repo

# $env:HOME is what a child pwsh reads at startup; $HOME is what THIS session
# already resolved, and preheat.ps1 runs in-process here - so both have to move.
# launchctl bootstrap accepts a plist from any path.
$e2eHome = Join-Path $env:RUNNER_TEMP 'clr-e2e-home'
New-Item -ItemType Directory -Path (Join-Path $e2eHome 'Library/LaunchAgents') -Force | Out-Null
$env:HOME = $e2eHome
Set-Variable -Name HOME -Value $e2eHome -Scope Global -Force

$uid = & id -u
$already = & launchctl print ('gui/' + $uid) 2>&1 | Select-String 'com\.claude-preheat\.'
if ($already) {
    throw ('this machine already holds preheat LaunchAgents - refusing to run a destructive e2e here: ' +
        (($already | ForEach-Object Line) -join ', '))
}

# stub claude: first on PATH; the launchd job inherits this PATH via the
# plist's EnvironmentVariables snapshot taken at registration time
$stubDir = Join-Path ([System.IO.Path]::GetTempPath()) 'clr-e2e-stub'
New-Item -ItemType Directory -Path $stubDir -Force | Out-Null
$stub = Join-Path $stubDir 'claude'
# the stub answers like claude only when called the way preheat.ps1 calls it
# (-p ... --output-format stream-json --verbose): a fire whose argv drifted must FAIL here, not
# pass on a stub that says yes to anything
$stubBody = @(
    '#!/bin/bash',
    'args=" $* "',
    'for f in " -p " " --model haiku " " --no-session-persistence " " --strict-mcp-config " " --mcp-config " " --output-format stream-json " " --verbose "; do',
    '  case "$args" in *"$f"*) ;; *) echo "stub claude: missing$f in argv: $*" >&2; exit 2 ;; esac',
    'done',
    'echo ''{"type":"system","subtype":"init"}''',
    'echo ''{"type":"result","total_cost_usd":0.0001}''',
    ''
) -join "`n"
[System.IO.File]::WriteAllText($stub, $stubBody, (New-Object System.Text.UTF8Encoding($false)))
& chmod +x $stub

# stub codex in the same PATH dir: the shared test stub (app-server + exec)
# behind a bash launcher. The launchd child sees no STUB_* env, so the stub
# reads stub-config.json next to itself; plus5h + anchor = an idle 5h window
# that the ping freezes, which the post-read should call anchored.
Copy-Item (Join-Path $PSScriptRoot 'stub-codex.ps1') $stubDir -Force
$cxConfig = Join-Path $stubDir 'stub-config.json'
$cxCalls  = Join-Path $env:RUNNER_TEMP 'stub-codex-calls.txt'
$cxState  = Join-Path $env:RUNNER_TEMP 'stub-codex-state.json'
function Set-StubCodex([string]$StubProfile) {
    $c = [ordered]@{ profile = $StubProfile; r5 = $null; anchor = $true; exec = 'ok'; rpc = 'ok'; callsLog = $cxCalls; state = $cxState }
    Remove-Item $cxState -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllText($cxConfig, (ConvertTo-Json -InputObject $c -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
}
Set-StubCodex 'plus5h'
$cxStub = Join-Path $stubDir 'codex'
$cxBody = @(
    '#!/bin/bash',
    ('exec "' + (Get-Process -Id $PID).Path + '" -NoProfile -NonInteractive -File "$(dirname "$0")/stub-codex.ps1" "$@"'),
    ''
) -join "`n"
[System.IO.File]::WriteAllText($cxStub, $cxBody, (New-Object System.Text.UTF8Encoding($false)))
& chmod +x $cxStub
$env:PATH = "$stubDir" + ':' + $env:PATH
# anything this session itself asks of codex goes to the stub as well
$env:PREHEAT_CODEX_EXE = $cxStub

Write-Host '--- register a one-shot preheat (+2m) through launchd ---'
# journal baseline BEFORE scheduling: only lines written after this count as
# the fire (a pre-existing "ev":"fire" line must not green-light the run)
$log = Join-Path $repo 'preheat-log.jsonl'
$baseLines = 0
if (Test-Path $log) { $baseLines = @(Get-Content $log).Count }

function Wait-FireLine([int]$From, [scriptblock]$Match, [int]$Sec) {
    # the newest journal fire line after line $From that $Match accepts, or $null
    $deadline = (Get-Date).AddSeconds($Sec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        if (Test-Path $log) {
            $all = @(Get-Content $log)
            if ($all.Count -gt $From) {
                $line = $all[$From..($all.Count - 1)] | Where-Object { ($_ -like '*"ev":"fire"*') -and (& $Match $_) } | Select-Object -Last 1
                if ($line) { return $line }
            }
        }
    }
    $null
}
function Show-LaunchdState {
    $errLog = Join-Path $repo 'launchd-err.log'
    if (Test-Path $errLog) { Write-Host '--- launchd-err.log ---'; Get-Content $errLog }
    & launchctl print ('gui/' + $uid) 2>&1 | Select-String 'claude-preheat' | ForEach-Object { Write-Host $_.Line }
}

# everything from here on is torn down in the finally, including on a throw:
# a job left registered would keep firing on the runner and, worse, a local
# misfire of this script would leave the machine armed
try {
    # a Claude and a Codex one-shot in the same minute: both must fire
    ./preheat.ps1 +2m
    ./preheat.ps1 +2m -Codex

    $st = ./preheat.ps1 status -Json | ConvertFrom-Json
    if (@($st.tasks).Count -lt 2) { throw 'the two one-shots are not both visible in status -Json' }
    if (@($st.tasks | Where-Object { $_.provider -eq 'codex' }).Count -ne 1) { throw 'the Codex one-shot is not tagged provider codex in status -Json' }
    foreach ($t in @($st.tasks)) { Write-Host ('scheduled: {0}  next={1}  provider={2}' -f $t.name, $t.next, $t.provider) }

    Write-Host '--- wait for launchd to fire both (the Codex verdict reads ~2 min after its ping) ---'
    $fired = Wait-FireLine $baseLines { param($l) $l -notlike '*"provider":"codex"*' } 200
    if (-not $fired) { Show-LaunchdState; throw 'launchd never fired the Claude preheat within 200s' }
    Write-Host "fire journal: $fired"
    if ($fired -notlike '*"ok":true*') { throw 'fire ran but the (stubbed) ping failed' }
    $cxFired = Wait-FireLine $baseLines { param($l) $l -like '*"provider":"codex"*' } 300
    if (-not $cxFired) { Show-LaunchdState; throw 'launchd never fired the Codex preheat within 200s + 300s' }
    Write-Host "codex fire journal: $cxFired"
    if (($cxFired -notlike '*"ok":true*') -or ($cxFired -notlike '*"pinged":true*')) { throw 'the Codex fire ran but did not ping successfully' }
    # the stub is deterministic (idle window, an exec that anchors it): any
    # other verdict is a regression in the judging, not runner noise
    if ($cxFired -notlike '*"state":"anchored"*') { throw 'the Codex verdict was not anchored' }
    # no plist check for the spent one-shot here: the launchd child runs with
    # the runner's real HOME (the plist bakes PATH only), so its self-delete
    # looks in the real LaunchAgents dir, not $e2eHome - test.ps1 covers it
    $execRuns = @(Get-Content $cxCalls -ErrorAction SilentlyContinue | Where-Object { $_ -like 'exec stdin=*' }).Count
    if ($execRuns -lt 1) { throw 'the Codex fire journaled a ping but the stub calls log has no exec line (a different codex ran?)' }

    Write-Host '--- an account with no 5h window (free 30d): the Codex fire must refuse to ping ---'
    Set-StubCodex 'free30d'
    $base2 = @(Get-Content $log).Count
    ./preheat.ps1 +2m -Codex
    $noFire = Wait-FireLine $base2 { param($l) $l -like '*"provider":"codex"*' } 200
    if (-not $noFire) { Show-LaunchdState; throw 'launchd never fired the free30d Codex preheat within 200s' }
    Write-Host "codex no5h journal: $noFire"
    if (($noFire -notlike '*"kind":"no5h"*') -or ($noFire -notlike '*"pinged":false*')) { throw 'a free 30d account was not refused with kind no5h / pinged false' }
    if (@(Get-Content $cxCalls | Where-Object { $_ -like 'exec stdin=*' }).Count -ne $execRuns) { throw 'the free 30d fire ran codex exec' }

    # the read-only allow-list held across every launchd-spawned codex child
    $allowed = @('initialize', 'initialized', 'account/read', 'account/rateLimits/read')
    if (-not (Test-Path $cxCalls)) { throw 'the stub calls log was never written' }
    foreach ($l in @(Get-Content $cxCalls | Where-Object { $_ -like 'rpc *' })) {
        if ($allowed -notcontains ($l.Split(' ')[1])) { throw ('a non-allow-listed RPC reached codex: ' + $l) }
    }
} finally {
    Write-Host '--- cleanup: preheat off, then bootout whatever launchd still holds ---'
    try { ./preheat.ps1 off } catch { Write-Host ('preheat off failed: ' + $_.Exception.Message) }
    # off only removes what it can still see; a label whose plist vanished stays
    # loaded and keeps firing until logout, so sweep by what launchd reports
    $held = & launchctl print ('gui/' + $uid) 2>&1 | Select-String 'com\.claude-preheat\.[A-Za-z0-9-]+'
    foreach ($label in @($held | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } | Select-Object -Unique)) {
        Write-Host ('bootout ' + $label)
        & launchctl bootout ('gui/' + $uid + '/' + $label) 2>&1 | Out-Null
    }
    Remove-Item $stubDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '--- cleanup must leave zero plists AND zero loaded agents ---'
$left = @(Get-ChildItem (Join-Path $e2eHome 'Library/LaunchAgents') -Filter 'com.claude-preheat.*' -ErrorAction SilentlyContinue)
if ($left.Count -ne 0) { throw ('leftover plists: ' + ($left.Name -join ', ')) }
# the plist file gone is only half the removal: launchd itself must have
# dropped the label, else the agent keeps firing until logout
$loaded = & launchctl print ('gui/' + $uid) 2>&1 | Select-String 'com\.claude-preheat'
if ($loaded) { throw ('launchd still holds: ' + (($loaded | ForEach-Object Line) -join ', ')) }
Write-Host 'E2E PASS: schedule -> launchd fire (Claude + Codex) -> journal -> clean removal'
