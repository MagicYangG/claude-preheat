#Requires -Version 7.0
# macOS end-to-end: schedule -> launchd fires -> pwsh fire -> (stubbed) claude
# -> journal -> clean removal. CI-only: registers a REAL user LaunchAgent on
# the runner and removes it again. The only unstubbed piece of the whole chain
# is the claude binary itself (needs a real subscription - beta testers cover it).
$ErrorActionPreference = 'Stop'
# 'preheat off' below removes EVERY ClaudePreheat job - never run this on a
# Mac that carries a real schedule
if (-not $env:CI) { throw 'CI-only: this script wipes the whole preheat schedule at the end' }
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Set-Location $repo

# stub claude: first on PATH; the launchd job inherits this PATH via the
# plist's EnvironmentVariables snapshot taken at registration time
$stubDir = Join-Path ([System.IO.Path]::GetTempPath()) 'clr-e2e-stub'
New-Item -ItemType Directory -Path $stubDir -Force | Out-Null
$stub = Join-Path $stubDir 'claude'
"#!/bin/bash`necho '{`"type`":`"result`",`"total_cost_usd`":0.0001}'`n" | Set-Content -Path $stub -NoNewline
& chmod +x $stub
$env:PATH = "$stubDir" + ':' + $env:PATH

Write-Host '--- register a one-shot preheat (+2m) through launchd ---'
# journal baseline BEFORE scheduling: only lines written after this count as
# the fire (a pre-existing "ev":"fire" line must not green-light the run)
$log = Join-Path $repo 'preheat-log.jsonl'
$baseLines = 0
if (Test-Path $log) { $baseLines = @(Get-Content $log).Count }
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
    & launchctl print ('gui/' + (& id -u)) 2>&1 | Select-String 'claude-preheat' | ForEach-Object { Write-Host $_.Line }
    throw 'launchd never fired the preheat within 200s'
}
Write-Host "fire journal: $fired"
if ($fired -notlike '*"ok":true*') { throw 'fire ran but the (stubbed) ping failed' }

Write-Host '--- preheat off must leave zero plists AND zero loaded agents ---'
./preheat.ps1 off
$left = @(Get-ChildItem (Join-Path $HOME 'Library/LaunchAgents') -Filter 'com.claude-preheat.*' -ErrorAction SilentlyContinue)
if ($left.Count -ne 0) { throw ('leftover plists: ' + ($left.Name -join ', ')) }
# the plist file gone is only half the removal: launchd itself must have
# dropped the label, else the agent keeps firing until logout
$loaded = & launchctl print ('gui/' + (& id -u)) 2>&1 | Select-String 'com\.claude-preheat'
if ($loaded) { throw ('launchd still holds: ' + (($loaded | ForEach-Object Line) -join ', ')) }
Write-Host 'E2E PASS: schedule -> launchd fire -> journal -> clean removal'
