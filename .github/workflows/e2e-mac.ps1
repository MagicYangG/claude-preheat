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
$env:PATH = "$stubDir" + ':' + $env:PATH

Write-Host '--- register a one-shot preheat (+2m) through launchd ---'
# journal baseline BEFORE scheduling: only lines written after this count as
# the fire (a pre-existing "ev":"fire" line must not green-light the run)
$log = Join-Path $repo 'preheat-log.jsonl'
$baseLines = 0
if (Test-Path $log) { $baseLines = @(Get-Content $log).Count }

# everything from here on is torn down in the finally, including on a throw:
# a job left registered would keep firing on the runner and, worse, a local
# misfire of this script would leave the machine armed
try {
    ./preheat.ps1 +2m

    $st = ./preheat.ps1 status -Json | ConvertFrom-Json
    if (@($st.tasks).Count -lt 1) { throw 'once job not visible in status -Json' }
    Write-Host ('scheduled: {0}  next={1}' -f $st.tasks[0].name, $st.tasks[0].next)

    Write-Host '--- wait for launchd to fire (up to 200s) ---'
    $deadline = (Get-Date).AddSeconds(200)
    $fired = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        if (Test-Path $log) {
            $all = @(Get-Content $log)
            if ($all.Count -gt $baseLines) {
                $line = $all[$baseLines..($all.Count - 1)] | Where-Object { $_ -like '*"ev":"fire"*' } | Select-Object -Last 1
                if ($line) { $fired = $line; break }
            }
        }
    }
    if (-not $fired) {
        $errLog = Join-Path $repo 'launchd-err.log'
        if (Test-Path $errLog) { Write-Host '--- launchd-err.log ---'; Get-Content $errLog }
        & launchctl print ('gui/' + $uid) 2>&1 | Select-String 'claude-preheat' | ForEach-Object { Write-Host $_.Line }
        throw 'launchd never fired the preheat within 200s'
    }
    Write-Host "fire journal: $fired"
    if ($fired -notlike '*"ok":true*') { throw 'fire ran but the (stubbed) ping failed' }
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
Write-Host 'E2E PASS: schedule -> launchd fire -> journal -> clean removal'
