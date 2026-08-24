#Requires -Version 5.1
<#
platform.ps1 -- OS adapter for claude-preheat. Dot-sourced by preheat.ps1 and
panel.ps1; never run directly.

One scheduling contract, two backends:
  Windows : Task Scheduler (Register-ScheduledTask; wake timers can wake the PC)
  macOS   : launchd user LaunchAgents (~/Library/LaunchAgents/com.claude-preheat.*)

Job names are identical on both platforms (ClaudePreheat-Wk-HHmm-Days and
ClaudePreheat-Once-yyyyMMdd-HHmm). On macOS a name maps 1:1 to the launchd
label com.claude-preheat.<name minus the ClaudePreheat- prefix>, and the NAME
is the schedule: launchd has no NextRunTime query, so next-fire times are
recomputed from the name alone (Get-JobNextRun).

macOS parity gap, on purpose: launchd cannot wake a sleeping Mac. A fire that
comes due while the Mac sleeps runs once on wake - a late anchor, same effect
as the user's own first message, never worse than not being installed.
Test-WakeTimers prints the platform-appropriate warning.
#>

$OnMac = $false
try { if ($IsMacOS) { $OnMac = $true } } catch { }
# $IsMacOS does not exist on Windows PowerShell 5.1 - the try keeps 5.1 quiet

$PlatformRoot       = $PSScriptRoot
$JobNamePrefix      = 'ClaudePreheat-'
$LaunchdLabelPrefix = 'com.claude-preheat.'
$LaunchAgentDir     = if ($OnMac) { Join-Path $HOME (Join-Path 'Library' 'LaunchAgents') } else { $null }
$LaunchdErrLog      = Join-Path $PlatformRoot 'launchd-err.log'

function Get-ClaudeHome {
    # USERPROFILE wins when present (Windows reality, and how tests redirect the
    # home dir in-process); macOS has no USERPROFILE and falls through to $HOME
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    $HOME
}

function Resolve-HostShell {
    $p = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($p) { return $p.Source }
    # we ARE a PowerShell - the running host binary is always a valid fallback
    # (matters on macOS where 'powershell' does not exist)
    try {
        $self = (Get-Process -Id $PID).Path
        if ($self) { return $self }
    } catch { }
    (Get-Command powershell).Source
}

function Get-MacUid {
    if (-not $script:MacUid) { $script:MacUid = (& id -u).Trim() }
    $script:MacUid
}

# ---------- name <-> label <-> schedule (macOS) ----------

function ConvertTo-LaunchdLabel([string]$name)   { $LaunchdLabelPrefix + $name.Substring($JobNamePrefix.Length) }
function ConvertFrom-LaunchdLabel([string]$label) { $JobNamePrefix + $label.Substring($LaunchdLabelPrefix.Length) }

function Get-JobNextRun([string]$name) {
    # the job name carries its whole schedule - see the header note
    if ($name -match '^ClaudePreheat-Once-(\d{8})-(\d{4})$') {
        try { return [datetime]::ParseExact($Matches[1] + $Matches[2], 'yyyyMMddHHmm', $null) } catch { return $null }
    }
    if ($name -match '^ClaudePreheat-Wk-(\d{2})(\d{2})-([A-Za-z]+)$') {
        $tod  = New-Object timespan ([int]$Matches[1]), ([int]$Matches[2]), 0
        $tags = $Matches[3]
        $map  = @{ Mon = 'Monday'; Tue = 'Tuesday'; Wed = 'Wednesday'; Thu = 'Thursday'; Fri = 'Friday'; Sat = 'Saturday'; Sun = 'Sunday' }
        $best = $null
        for ($i = 0; $i + 3 -le $tags.Length; $i += 3) {
            $full = $map[$tags.Substring($i, 3)]
            if (-not $full) { continue }
            $cand = (Get-Date).Date + $tod
            $guard = 0
            while ((($cand.DayOfWeek.ToString() -ne $full) -or ($cand -le (Get-Date))) -and ($guard -lt 9)) {
                $cand = $cand.AddDays(1); $guard++
            }
            if ((-not $best) -or ($cand -lt $best)) { $best = $cand }
        }
        return $best
    }
    $null
}

function Build-LaunchdPlist {
    # PURE - returns the plist XML as a string, so it is testable on any OS.
    # $Days empty -> one-shot (Month/Day pinned; the yearly recurrence that
    # implies is neutralized by Remove-StaleOnceJobs at the next fire/apply).
    param(
        [string]$Name,
        [string[]]$Days,          # full names (Monday..Sunday), may be empty
        [datetime]$At,
        [string]$HostShell,
        [string]$ScriptPath,
        [string]$PathEnv
    )
    $e = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
    $label  = ConvertTo-LaunchdLabel $Name
    $dayNum = @{ Sunday = 0; Monday = 1; Tuesday = 2; Wednesday = 3; Thursday = 4; Friday = 5; Saturday = 6 }
    if ($Days -and $Days.Count -gt 0) {
        $entries = foreach ($d in $Days) {
            '        <dict><key>Weekday</key><integer>{0}</integer><key>Hour</key><integer>{1}</integer><key>Minute</key><integer>{2}</integer></dict>' -f $dayNum[$d], $At.Hour, $At.Minute
        }
        $cal = "    <key>StartCalendarInterval</key>`n    <array>`n" + ($entries -join "`n") + "`n    </array>"
    } else {
        $cal = '    <key>StartCalendarInterval</key>' + "`n" +
               ('    <dict><key>Month</key><integer>{0}</integer><key>Day</key><integer>{1}</integer><key>Hour</key><integer>{2}</integer><key>Minute</key><integer>{3}</integer></dict>' -f $At.Month, $At.Day, $At.Hour, $At.Minute)
    }
    # launchd starts jobs with a minimal PATH - snapshot the registering shell's
    # PATH so the fire can find claude/node exactly like an interactive shell
    @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$(& $e $label)</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(& $e $HostShell)</string>
        <string>-NoProfile</string>
        <string>-File</string>
        <string>$(& $e $ScriptPath)</string>
        <string>fire</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>PATH</key><string>$(& $e $PathEnv)</string></dict>
$cal
    <key>StandardErrorPath</key><string>$(& $e $LaunchdErrLog)</string>
</dict>
</plist>
"@
}

# ---------- Windows-only scheduler internals ----------

function New-PreheatAction {
    # via run-hidden.vbs: a console action flashes a cmd window at every fire
    New-ScheduledTaskAction -Execute 'wscript.exe' `
        -Argument ('//B //Nologo "{0}" "{1}" "-NoProfile" "-ExecutionPolicy" "Bypass" "-File" "{2}" "fire"' -f `
            (Join-Path $PlatformRoot 'run-hidden.vbs'), (Resolve-HostShell), (Join-Path $PlatformRoot 'preheat.ps1'))
}

function New-PreheatSettings {
    New-ScheduledTaskSettingsSet -WakeToRun -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
}

# ---------- the scheduling contract ----------

function Register-PreheatJob {
    # $Days present -> weekly at $At's time-of-day on those days
    # $Days absent  -> one-shot at $At
    param([string]$Name, [string[]]$Days, [datetime]$At)
    if ($OnMac) {
        if (-not (Test-Path $LaunchAgentDir)) { New-Item -ItemType Directory -Path $LaunchAgentDir -Force | Out-Null }
        $label = ConvertTo-LaunchdLabel $Name
        $plist = Join-Path $LaunchAgentDir ($label + '.plist')
        $xml   = Build-LaunchdPlist -Name $Name -Days $Days -At $At `
                    -HostShell (Resolve-HostShell) -ScriptPath (Join-Path $PlatformRoot 'preheat.ps1') -PathEnv $env:PATH
        # plists must not carry a BOM
        [System.IO.File]::WriteAllText($plist, $xml, (New-Object System.Text.UTF8Encoding($false)))
        $uid = Get-MacUid
        & launchctl bootout "gui/$uid/$label" 2>$null | Out-Null      # idempotent re-register
        & launchctl bootstrap "gui/$uid" $plist 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "launchctl bootstrap failed for $label (exit $LASTEXITCODE)" }
    } else {
        $trigger = if ($Days -and $Days.Count -gt 0) { New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Days -At $At }
                   else { New-ScheduledTaskTrigger -Once -At $At }
        Register-ScheduledTask -TaskName $Name -Action (New-PreheatAction) -Trigger $trigger -Settings (New-PreheatSettings) -Force | Out-Null
    }
}

function Get-PreheatJobs {
    # -> array of @{ name = <string>; next = <datetime or $null> }
    param([string]$Pattern = 'ClaudePreheat*')
    $jobs = @()
    if ($OnMac) {
        if (Test-Path $LaunchAgentDir) {
            foreach ($f in @(Get-ChildItem -Path $LaunchAgentDir -Filter ($LaunchdLabelPrefix + '*.plist') -ErrorAction SilentlyContinue)) {
                $name = ConvertFrom-LaunchdLabel ([System.IO.Path]::GetFileNameWithoutExtension($f.Name))
                if ($name -notlike $Pattern) { continue }
                $jobs += @{ name = $name; next = (Get-JobNextRun $name) }
            }
        }
    } else {
        foreach ($t in @(Get-ScheduledTask -TaskName $Pattern -ErrorAction SilentlyContinue)) {
            $info = $t | Get-ScheduledTaskInfo
            $next = $null
            if ($info.NextRunTime) { $next = $info.NextRunTime }
            $jobs += @{ name = $t.TaskName; next = $next }
        }
    }
    $jobs
}

function Remove-PreheatJobs {
    param([string]$Pattern = 'ClaudePreheat*')
    if ($OnMac) {
        $uid = Get-MacUid
        foreach ($j in @(Get-PreheatJobs $Pattern)) {
            $label = ConvertTo-LaunchdLabel $j.name
            & launchctl bootout "gui/$uid/$label" 2>$null | Out-Null
            Remove-Item (Join-Path $LaunchAgentDir ($label + '.plist')) -Force -ErrorAction SilentlyContinue
        }
    } else {
        Get-ScheduledTask -TaskName $Pattern -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
    }
}

function Remove-StaleOnceJobs {
    # a fired one-shot must not linger: on Windows its trigger is spent, on
    # macOS the Month/Day calendar spec would come around AGAIN next year
    if ($OnMac) {
        foreach ($j in @(Get-PreheatJobs 'ClaudePreheat-Once*')) {
            if ($j.next -and ($j.next -lt (Get-Date).AddMinutes(-3))) {
                Remove-PreheatJobs $j.name
            }
        }
    } else {
        Get-ScheduledTask -TaskName 'ClaudePreheat-Once*' -ErrorAction SilentlyContinue | ForEach-Object {
            $info = $_ | Get-ScheduledTaskInfo
            if (-not $info.NextRunTime -or $info.NextRunTime -lt (Get-Date).AddMinutes(-3)) {
                $_ | Unregister-ScheduledTask -Confirm:$false
            }
        }
    }
}

# ---------- platform warnings + notifications ----------

function Test-WakeTimers {
    if ($OnMac) {
        # launchd cannot wake a sleeping Mac - warn when the machine is set to
        # sleep at all, because a fire during sleep lands late (on wake)
        try {
            $out = & pmset -g 2>$null
            $line = ($out | Select-String '^\s*sleep\s+(\d+)' | Select-Object -First 1)
            if ($line -and $line.Matches[0].Groups[1].Value -ne '0') {
                Write-Warning ('macOS sleeps after {0} min idle - a preheat due during sleep fires late (on wake). Keep the Mac awake across fire times (plugged in, caffeinate, or Energy Saver "Prevent automatic sleeping"), or accept late anchors.' -f $line.Matches[0].Groups[1].Value)
            }
        } catch { }
        return
    }
    # Windows: warn if wake timers are disabled in the active power plan (AC)
    try {
        $out = powercfg /query SCHEME_CURRENT SUB_SLEEP RTCWAKE 2>$null
        # locale-invariant: first line containing a 0x value is the AC setting index
        # (localized label text would mojibake under BOM-less UTF-8 on powershell.exe 5.1)
        $line = ($out | Select-String '0x[0-9a-fA-F]{8}' | Select-Object -First 1)
        if ($line) {
            $v = $line.ToString()
            if ($v -match '0x0+$') {
                Write-Warning 'Wake timers DISABLED on AC power - preheat cannot wake the PC from sleep. Enable: powercfg -> Sleep -> Allow wake timers'
            } elseif ($v -match '0x0*2$') {
                Write-Warning 'Wake timers = "important only" - a user scheduled task may NOT wake the PC. Set to Enabled to be safe.'
            }
        }
    } catch { }
}

function Send-Toast($ok) {
    $msg = if ($ok) { 'window preheated' } else { 'preheat FAILED - check preheat-log.jsonl' }
    try {
        if ($OnMac) {
            & osascript -e ('display notification "{0}" with title "claude-preheat"' -f $msg) 2>$null | Out-Null
            return
        }
        if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast -ErrorAction Stop
            New-BurntToastNotification -Text 'claude-preheat', $msg | Out-Null
        }
    } catch { }
}
