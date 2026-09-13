#Requires -Version 5.1
<#
platform.ps1 -- OS adapter for claude-preheat. Dot-sourced by preheat.ps1,
panel.ps1 and install.ps1; never run directly.

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
$OnLinux = $false
try { if ($IsLinux) { $OnLinux = $true } } catch { }
# three states, not two: everything below assumes "mac or Windows". On Linux
# the Windows branch would run and fail deep inside Task Scheduler cmdlets with
# an unrelated message - say it here instead.
if ($OnLinux) { throw 'claude-preheat supports Windows and macOS only - there is no scheduler backend for Linux' }

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

function Backup-File([string]$Path) {
    # timestamped copy taken just before an in-place rewrite; returns the backup
    # path, or $null when there was nothing worth copying. Never throws: a
    # failed backup must not abort the operation it was only guarding.
    try {
        if ((Test-Path $Path) -and ((Get-Item $Path).Length -gt 0)) {
            $bak = $Path + '.bak-' + (Get-Date).ToString('yyyyMMdd-HHmmss')
            Copy-Item $Path $bak -Force
            # keep the five newest: the panel's Save & apply would otherwise
            # leave a fresh .bak-* behind on every click, forever (they are
            # gitignored, so nobody would notice the pile)
            Get-ChildItem -Path (Split-Path $Path -Parent) -Filter ((Split-Path $Path -Leaf) + '.bak-*') -File -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -Skip 5 |
                Remove-Item -Force -ErrorAction SilentlyContinue
            return $bak
        }
    } catch { }
    $null
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    # 5.1's Set-Content -Encoding UTF8 stamps a BOM, and a BOM-poisoned JSON
    # file breaks strict parsers (Claude Code's settings reader among them)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Resolve-HostShell {
    if ($OnMac) {
        # pwsh prepends $PSHOME to PATH, so a plain Get-Command inside pwsh finds
        # the bare $PSHOME binary before the launcher on the user's own PATH.
        # Under Homebrew's formula those are not interchangeable:
        # /opt/homebrew/bin/pwsh is a wrapper that exports DOTNET_ROOT (the
        # formula links the shared dotnet instead of bundling a runtime) and the
        # bare binary exits with "You must install .NET". Baked into a plist or a
        # shim that is a job that can never run - so do not just prefer a path
        # outside $PSHOME, PROVE it launches before baking it in.
        if ($script:HostShellCache) { return $script:HostShellCache }
        $cands = @()
        foreach ($c in @(Get-Command pwsh -All -ErrorAction SilentlyContinue)) {
            if ($c.Source) { $cands += $c.Source }
        }
        $cands += @('/opt/homebrew/bin/pwsh', '/usr/local/bin/pwsh', '/usr/local/microsoft/powershell/7/pwsh')
        $seen = @{}
        foreach ($cand in $cands) {
            if (-not $cand) { continue }
            if ($seen[$cand]) { continue }
            $seen[$cand] = $true
            if ((Split-Path $cand -Parent) -eq $PSHOME) { continue }
            if (-not (Test-Path $cand)) { continue }
            try {
                # do NOT pre-seed $LASTEXITCODE here: assigning it makes a LOCAL
                # copy that the engine never updates, so the check below would
                # read the seed forever and no candidate could ever pass
                & $cand -NoProfile -NonInteractive -Command '1' 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { $script:HostShellCache = $cand; return $cand }
            } catch { }
        }
        # every candidate outside $PSHOME is broken or absent (self-contained pkg
        # installs have none) - fall through to the bare binary below
    }
    if ($script:HostShellCache) { return $script:HostShellCache }
    $p = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($p) {
        $script:HostShellCache = Resolve-StoreShellAlias $p.Source
        return $script:HostShellCache
    }
    # we ARE a PowerShell - the running host binary is always a valid fallback
    # (matters on macOS where 'powershell' does not exist)
    try {
        $self = (Get-Process -Id $PID).Path
        if ($self) { return $self }
    } catch { }
    (Get-Command powershell).Source
}

function Resolve-StoreShellAlias {
    # Windows twin of the Homebrew trap above. A Store-installed pwsh resolves to
    # its VERSIONED package folder
    #   C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe
    # and every Store update replaces that folder. A path baked into a scheduled
    # task then dies at the next update - silently, because run-hidden.vbs used
    # to exit 0 on a missing exe (observed 2026-09-10: 7.6.4 -> 7.6.6, two fires
    # and the panel gone, every task still green). The App Execution Alias under
    # %LOCALAPPDATA%\Microsoft\WindowsApps survives updates, so bake THAT - but
    # PROVE it launches first: aliases can be switched off in Settings > Apps.
    # Anything that is not a versioned Store path comes back untouched.
    param([string]$Path, [string]$AliasRoot = $null)
    if (-not $Path) { return $Path }
    if ($Path -match '\\WindowsApps\\(Microsoft\.PowerShell)_\d[^\\]*__([^\\_]+)\\pwsh\.exe$') {
        $pkg = $Matches[1]; $publisher = $Matches[2]
        if (-not $AliasRoot) { $AliasRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps' }
        $cands = @((Join-Path $AliasRoot ($pkg + '_' + $publisher + '\pwsh.exe')),   # per-package alias
                   (Join-Path $AliasRoot 'pwsh.exe'))                                # generic alias
        foreach ($cand in $cands) {
            if (-not (Test-Path $cand)) { continue }
            try {
                # same rule as the mac branch: never pre-seed $LASTEXITCODE
                & $cand -NoProfile -NonInteractive -Command '1' 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { return $cand }
            } catch { }
        }
    }
    $Path
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
        # InvariantCulture, not $null: $null means CurrentCulture, and a non-
        # Gregorian calendar (th-TH, ar-SA) parses these digits into a wrong year
        try { return [datetime]::ParseExact($Matches[1] + $Matches[2], 'yyyyMMddHHmm', [System.Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
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
    <dict><key>PATH</key><string>$(& $e $PathEnv)</string><key>CLAUDE_PREHEAT_SELF</key><string>$(& $e $Name)</string></dict>
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

function New-PreheatSettings([switch]$NoWake) {
    # -AllowStartIfOnBatteries / -DontStopIfGoingOnBatteries: the default is to
    # skip (or kill) the task on battery, and one haiku ping is not worth losing
    # the whole day's anchor over an unplugged laptop.
    # -StartWhenAvailable is deliberately NOT set: a missed fire replayed at
    # logon would anchor the 5h window at that moment, which is worse than
    # skipping it. The task runs as an Interactive logon type, so it only fires
    # while the user is logged in (a locked screen is fine).
    $p = @{ AllowStartIfOnBatteries = $true; DontStopIfGoingOnBatteries = $true
            ExecutionTimeLimit = (New-TimeSpan -Minutes 30); MultipleInstances = 'IgnoreNew' }
    # a chase (follow-up preheat) is best effort: it never wakes a sleeping PC
    if (-not $NoWake) { $p.WakeToRun = $true }
    New-ScheduledTaskSettingsSet @p
}

# ---------- the scheduling contract ----------

function Register-PreheatJob {
    # $Days present -> weekly at $At's time-of-day on those days
    # $Days absent  -> one-shot at $At
    param([string]$Name, [string[]]$Days, [datetime]$At, [switch]$NoWake)
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
        # bootout is asynchronous: the label can still be tearing down when the
        # bootstrap right behind it arrives, and launchd answers with a
        # transient "service already loaded"/busy error. Retry before giving up.
        $booted = $false
        for ($i = 1; $i -le 3 -and -not $booted; $i++) {
            & launchctl bootstrap "gui/$uid" $plist 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $booted = $true }
            elseif ($i -lt 3) { Start-Sleep -Seconds 1 }
        }
        if (-not $booted) {
            # a plist launchd never accepted must not linger: status trusts plist files
            Remove-Item $plist -Force -ErrorAction SilentlyContinue
            throw "launchctl bootstrap failed for $label (exit $LASTEXITCODE)"
        }
    } else {
        $trigger = if ($Days -and $Days.Count -gt 0) { New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Days -At $At }
                   else { New-ScheduledTaskTrigger -Once -At $At }
        Register-ScheduledTask -TaskName $Name -Action (New-PreheatAction) -Trigger $trigger -Settings (New-PreheatSettings -NoWake:$NoWake) -Force | Out-Null
    }
}

function Get-PreheatJobs {
    # -> array of @{ name = <string>; next = <datetime or $null>; script = <string or $null>; shell = <string or $null> }
    # `script` is the preheat.ps1 path BAKED INTO the job. Moving or renaming the
    # repo leaves the job registered and still showing a next run while every
    # fire is a silent no-op - status compares this against the filesystem.
    # `shell` is the host binary baked next to it - it disappears when a Store
    # pwsh update replaces its versioned folder (see Resolve-StoreShellAlias).
    param([string]$Pattern = 'ClaudePreheat*')
    $jobs = @()
    if ($OnMac) {
        if (Test-Path $LaunchAgentDir) {
            foreach ($f in @(Get-ChildItem -Path $LaunchAgentDir -Filter ($LaunchdLabelPrefix + '*.plist') -ErrorAction SilentlyContinue)) {
                $name = ConvertFrom-LaunchdLabel ([System.IO.Path]::GetFileNameWithoutExtension($f.Name))
                if ($name -notlike $Pattern) { continue }
                $scriptPath = $null
                $shellPath  = $null
                try {
                    $plistText = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
                    if ($plistText -and ($plistText -match '<string>([^<]*preheat\.ps1)</string>')) { $scriptPath = $Matches[1] }
                    # first ProgramArguments entry is the host shell
                    if ($plistText -and ($plistText -match '<key>ProgramArguments</key>\s*<array>\s*<string>([^<]+)</string>')) { $shellPath = $Matches[1] }
                } catch { }
                $jobs += @{ name = $name; next = (Get-JobNextRun $name); script = $scriptPath; shell = $shellPath }
            }
        }
    } else {
        foreach ($t in @(Get-ScheduledTask -TaskName $Pattern -ErrorAction SilentlyContinue)) {
            $info = $t | Get-ScheduledTaskInfo
            $next = $null
            if ($info.NextRunTime) { $next = $info.NextRunTime }
            $scriptPath = $null
            $shellPath  = $null
            try {
                $argStr = [string]$t.Actions[0].Arguments
                if ($argStr -match '"-File"\s+"([^"]+)"') { $scriptPath = $Matches[1] }
                # the argument right after the vbs shim is the host shell
                if ($argStr -match 'run-hidden\.vbs"\s+"([^"]+)"') { $shellPath = $Matches[1] }
            } catch { }
            $jobs += @{ name = $t.TaskName; next = $next; script = $scriptPath; shell = $shellPath }
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
            # never boot out the job whose fire is running right now: a fire that
            # launchd delivers late (wake from sleep) is already past-due by its
            # own name, and bootout would SIGTERM it before the ping
            if ($env:CLAUDE_PREHEAT_SELF -and ($j.name -eq $env:CLAUDE_PREHEAT_SELF)) { continue }
            if ($j.next -and ($j.next -lt (Get-Date).AddMinutes(-3))) {
                Remove-PreheatJobs $j.name
            }
        }
        # a fire deletes its OWN plist but cannot boot itself out (that would
        # SIGTERM the ping), so launchd keeps holding those labels. They have no
        # plist left, so the loop above never sees them - sweep launchd directly.
        try {
            $uid = Get-MacUid
            $printed = (& launchctl print "gui/$uid" 2>$null) -join "`n"
            $selfLabel = $null
            if ($env:CLAUDE_PREHEAT_SELF) { $selfLabel = ConvertTo-LaunchdLabel $env:CLAUDE_PREHEAT_SELF }
            $done = @{}
            foreach ($m in [regex]::Matches($printed, 'com\.claude-preheat\.Once-\d{8}-\d{4}')) {
                $label = $m.Value
                if ($done[$label]) { continue }
                $done[$label] = $true
                if ($selfLabel -and ($label -eq $selfLabel)) { continue }
                if (Test-Path (Join-Path $LaunchAgentDir ($label + '.plist'))) { continue }
                & launchctl bootout "gui/$uid/$label" 2>$null | Out-Null
            }
        } catch { }
    } else {
        Get-ScheduledTask -TaskName 'ClaudePreheat-Once*' -ErrorAction SilentlyContinue | ForEach-Object {
            # never unregister a task whose instance is running: the vbs shim
            # now waits for the fire, so that instance may be THIS very process,
            # and deleting a running task can tear its process tree down
            if ($_.State -eq 'Running') { return }
            $info = $_ | Get-ScheduledTaskInfo
            if (-not $info.NextRunTime -or $info.NextRunTime -lt (Get-Date).AddMinutes(-3)) {
                $_ | Unregister-ScheduledTask -Confirm:$false
            }
        }
    }
}

function Limit-LaunchdErrLog {
    # launchd appends every fire's stderr here forever - unlike the journal
    # nothing else bounds it, so trim it whenever apply runs
    try {
        if ((Test-Path $LaunchdErrLog) -and ((Get-Item $LaunchdErrLog).Length -gt 1MB)) {
            $keep = Get-Content $LaunchdErrLog -Tail 200
            Set-Content -Path $LaunchdErrLog -Value $keep
        }
    } catch { }
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

function Send-Toast([bool]$Ok, $Anchored = $null, [string]$Kind = '', [string]$Extra = '') {
    # $Anchored: $true = this ping opened a fresh window, $false = it landed in
    # a window that was already running (harmless, but the toast should not
    # claim credit), $null = unknown. $Kind names the failure so an expired
    # login gets the one message that tells the user what to actually do.
    $msg = 'preheat FAILED - check preheat-log.jsonl'
    if ($Ok) {
        if ($null -eq $Anchored)   { $msg = 'window preheated' }
        elseif ($Anchored -eq $true) { $msg = 'window preheated - new 5h window anchored' }
        else                       { $msg = 'ping landed in a running window - anchor unchanged' }
        # e.g. " - chase at 16:38": the fire already booked the retry
        # the new part first, and short: a truncated banner drops the tail
        if ($Extra) { $msg = 'window busy' + $Extra }
    } elseif ($Kind -eq 'auth') {
        $msg = 'preheat FAILED - Claude login expired? run: claude'
    } elseif ($Kind -eq 'limit') {
        $msg = 'preheat skipped - usage limit already hit, nothing to preheat until it resets'
    }
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
