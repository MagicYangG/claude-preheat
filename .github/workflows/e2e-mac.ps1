#Requires -Version 7.0
# macOS end-to-end: schedule -> launchd fires -> pwsh fire -> (stubbed) claude
# -> journal -> clean removal. CI-only: registers a REAL user LaunchAgent on
# the runner and removes it again. The only unstubbed piece of the whole chain
# is the claude binary itself (needs a real subscription - beta testers cover it).
$ErrorActionPreference = 'Stop'
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
./preheat.ps1 +2m

$st = ./preheat.ps1 status -Json | ConvertFrom-Json
if (@($st.tasks).Count -lt 1) { throw 'once job not visible in status -Json' }
Write-Host ('scheduled: {0}  next={1}' -f $st.tasks[0].name, $st.tasks[0].next)

Write-Host '--- wait for launchd to fire (up to 200s) ---'
$log = Join-Path $repo 'preheat-log.jsonl'
$deadline = (Get-Date).AddSeconds(200)
$fired = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    if (Test-Path $log) {
        $line = Get-Content $log | Where-Object { $_ -like '*"ev":"fire"*' } | Select-Object -Last 1
        if ($line) { $fired = $line; break }
    }
}
if (-not $fired) { throw 'launchd never fired the preheat within 200s' }
Write-Host "fire journal: $fired"
if ($fired -notlike '*"ok":true*') { throw 'fire ran but the (stubbed) ping failed' }

Write-Host '--- preheat off must leave zero plists ---'
./preheat.ps1 off
$left = @(Get-ChildItem (Join-Path $HOME 'Library/LaunchAgents') -Filter 'com.claude-preheat.*' -ErrorAction SilentlyContinue)
if ($left.Count -ne 0) { throw ('leftover plists: ' + ($left.Name -join ', ')) }
Write-Host 'E2E PASS: schedule -> launchd fire -> journal -> clean removal'
