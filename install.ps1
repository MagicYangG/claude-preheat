# install.ps1 - idempotent setup for claude-preheat
# Safe to re-run: skips steps that are already done.

$ErrorActionPreference = 'Stop'
$repoDir = $PSScriptRoot
# one platform probe for the whole project: platform.ps1 owns $OnMac (and
# refuses Linux outright), so the installer cannot drift from what the
# scheduling backend believes it is running on
. (Join-Path $repoDir 'platform.ps1')

Write-Host "claude-preheat install" -ForegroundColor Cyan
Write-Host "repo dir: $repoDir"

# 1) schedule.json from example, if missing
$scheduleFile = Join-Path $repoDir 'schedule.json'
$exampleFile = Join-Path $repoDir 'schedule.example.json'
if (Test-Path $scheduleFile) {
    Write-Host "[skip] schedule.json already exists"
} else {
    if (Test-Path $exampleFile) {
        Copy-Item $exampleFile $scheduleFile
        Write-Host "[ok] created schedule.json from schedule.example.json"
    } else {
        Write-Warning "schedule.example.json not found, cannot create schedule.json"
    }
}

# 2) append functions to the CurrentUserAllHosts profile, guarded by marker comment
# (writing here instead of $PROFILE so the functions load for every host, not just
# whichever shell happens to run this installer)
$profilePath = $PROFILE.CurrentUserAllHosts
$markerBegin = '# >>> claude-preheat functions >>>'
$markerEnd = '# <<< claude-preheat functions <<<'
# v0.2 block markers: that block also defined a relay function whose script no
# longer ships, so migration must remove the whole old block
$oldMarkerBegin = '# >>> claude-limit-relay functions >>>'
$oldMarkerEnd = '# <<< claude-limit-relay functions <<<'

if (-not (Test-Path $profilePath)) {
    $profileDir = Split-Path $profilePath -Parent
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    New-Item -ItemType File -Path $profilePath -Force | Out-Null
}

# Read and write the profile through ONE explicit encoding. 5.1's Get-Content /
# Set-Content default to the ANSI codepage, so a profile holding non-ASCII text
# (a Chinese Windows username in a path, say) round-tripped to mojibake here.
# Sniff what the file actually is: a BOM (UTF-8 / UTF-16 / UTF-32) -> that
# encoding, BOM kept; decodes strictly as UTF-8 -> UTF-8 without BOM; neither
# -> the legacy ANSI codepage. A profile we create ourselves gets a UTF-8 BOM,
# which is what lets 5.1 read it back correctly.
$profileEnc = New-Object System.Text.UTF8Encoding($true)
$profileContent = ''
$profileBytes = New-Object byte[] 0
try { $profileBytes = [System.IO.File]::ReadAllBytes($profilePath) } catch { }
# BOM first, and not only the UTF-8 one: PS 5.1's own `>` / Out-File write
# UTF-16LE, so a profile the user started that way begins FF FE and must
# round-trip as UTF-16 - sniffed as "not UTF-8, so ANSI" it came back as
# U+FFFD soup and no shell could load it
$b = $profileBytes
$bomEnc = $null; $bomLen = 0
if ($b.Length -ge 4 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE -and $b[2] -eq 0 -and $b[3] -eq 0) { $bomEnc = New-Object System.Text.UTF32Encoding($false, $true); $bomLen = 4 }
elseif ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $bomEnc = New-Object System.Text.UTF8Encoding($true); $bomLen = 3 }
elseif ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { $bomEnc = New-Object System.Text.UnicodeEncoding($false, $true); $bomLen = 2 }
elseif ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { $bomEnc = New-Object System.Text.UnicodeEncoding($true, $true); $bomLen = 2 }
if ($bomEnc) {
    $profileEnc = $bomEnc
    $profileContent = $bomEnc.GetString($b, $bomLen, $b.Length - $bomLen)
} elseif ($b.Length -gt 0) {
    try {
        # throwOnInvalidBytes: the only reliable "is this really UTF-8" test
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        $profileContent = $strict.GetString($b)
        $profileEnc = New-Object System.Text.UTF8Encoding($false)
    } catch {
        # legacy codepage. [Encoding]::Default is the ANSI codepage only on
        # .NET Framework; on pwsh 7 it is UTF-8 and would turn a GBK profile
        # into U+FFFD. Ask for the culture's ANSI codepage by number (pwsh
        # needs the CodePages provider registered first) and fall back to
        # Latin-1, which round-trips every byte even when it cannot name it.
        $profileEnc = $null
        try {
            try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch { }
            $profileEnc = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
        } catch { $profileEnc = $null }
        if (-not $profileEnc) { $profileEnc = [System.Text.Encoding]::GetEncoding(28591) }
        $profileContent = $profileEnc.GetString($b)
    }
}

$preheatPath = Join-Path $repoDir 'preheat.ps1'
$panelPath = Join-Path $repoDir 'panel.ps1'

$block = @()
$block += $markerBegin
$block += "function preheat { & '$preheatPath' @args }"
$block += "function claude-panel { & '$panelPath' @args }"
$block += $markerEnd
$blockText = $block -join "`r`n"

$hasOld = $profileContent.Contains($oldMarkerBegin)
$markerPattern = [regex]::Escape($markerBegin) + '(?s).*?' + [regex]::Escape($markerEnd)
$existingMatch = [regex]::Match($profileContent, $markerPattern)

# skip only when the existing block is byte-identical to what we would write:
# comparing just the script path here once made content-only upgrades no-ops
if ($existingMatch.Success -and $existingMatch.Value -eq $blockText -and -not $hasOld) {
    Write-Host "[skip] $profilePath already has current claude-preheat functions"
} else {
    $backupPath = "$profilePath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $profilePath $backupPath -ErrorAction SilentlyContinue
    if (Test-Path $backupPath) {
        Write-Host "[ok] backed up $profilePath to $backupPath"
    }

    if ($hasOld) {
        # v0.2 -> v0.3: strip the old block so upgraders never end up with both
        $oldPattern = [regex]::Escape($oldMarkerBegin) + '(?s).*?' + [regex]::Escape($oldMarkerEnd)
        $profileContent = [regex]::Replace($profileContent, $oldPattern, '')
        $existingMatch = [regex]::Match($profileContent, $markerPattern)
    }

    if ($existingMatch.Success) {
        $before = $profileContent.Substring(0, $existingMatch.Index)
        $after = $profileContent.Substring($existingMatch.Index + $existingMatch.Length)
        [System.IO.File]::WriteAllText($profilePath, ($before + $blockText + $after), $profileEnc)
        Write-Host "[ok] updated claude-preheat functions in $profilePath"
    } elseif ($hasOld) {
        [System.IO.File]::WriteAllText($profilePath, ($profileContent + "`r`n$blockText`r`n"), $profileEnc)
        Write-Host "[ok] replaced v0.2 claude-limit-relay block with claude-preheat functions in $profilePath"
    } else {
        [System.IO.File]::WriteAllText($profilePath, ($profileContent + "`r`n$blockText`r`n"), $profileEnc)
        Write-Host "[ok] appended preheat / claude-panel functions to $profilePath"
    }
}

# 3) v0.2 -> v0.3 cleanup: relay is gone (claude CLI >= 2.1.234 auto-continues
# at limit reset natively). Only the relay probe task is ours to remove here -
# ClaudePreheat-* tasks are live and stay untouched. (Windows-only history:
# no v0.2 install ever existed on macOS.)
if (-not $OnMac) {
    $probeTask = Get-ScheduledTask -TaskName 'ClaudeRelay-Probe' -ErrorAction SilentlyContinue
    if ($probeTask) {
        Unregister-ScheduledTask -TaskName 'ClaudeRelay-Probe' -Confirm:$false
        Write-Host "[ok] removed v0.2 scheduled task ClaudeRelay-Probe"
    }
}
$legacyJson = @(Get-ChildItem -Path (Join-Path $repoDir 'armed'), (Join-Path $repoDir 'done') -Filter *.json -ErrorAction SilentlyContinue)
if ($legacyJson.Count -gt 0) {
    Write-Host "[note] armed\ and done\ hold v0.2 relay leftovers - inert now, safe to delete"
}

# 4) macOS: the profile functions only exist inside pwsh, but Mac users live in
# zsh - drop thin shims into ~/.local/bin so `preheat` / `claude-panel` work
# from any shell
if ($OnMac) {
    $binDir = Join-Path $HOME '.local/bin'
    if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }
    # same resolution the launchd plists use: a plain Get-Command would hand back
    # the naked $PSHOME binary, which under Homebrew cannot find .NET (see
    # Resolve-HostShell) and would bake a shim that dies on every call
    $pwshBin = Resolve-HostShell
    if (-not $pwshBin) { throw 'cannot resolve the pwsh binary path for the shims' }
    foreach ($pair in @(@('preheat', 'preheat.ps1'), @('claude-panel', 'panel.ps1'))) {
        $shim = Join-Path $binDir $pair[0]
        # single quotes: bash must not re-expand $ or backticks inside the paths
        $body = "#!/bin/bash`nexec '$pwshBin' -NoProfile -File '$(Join-Path $repoDir $pair[1])' `"`$@`"`n"
        [System.IO.File]::WriteAllText($shim, $body, (New-Object System.Text.UTF8Encoding($false)))
        & chmod +x $shim
        Write-Host "[ok] shim $shim"
    }
    # the same dir can sit on PATH as ~/.local/bin, as $HOME/.local/bin (the
    # shell already expanded it) or with a trailing slash - normalize before
    # deciding to nag
    $onPath = $false
    foreach ($p in @($env:PATH -split ':')) {
        $q = [string]$p
        if ($q -eq '~') { $q = $HOME } elseif ($q.StartsWith('~/', [System.StringComparison]::Ordinal)) { $q = $HOME + $q.Substring(1) }
        if ($q.Length -gt 1) { $q = $q.TrimEnd('/') }
        if ($q -ceq $binDir.TrimEnd('/')) { $onPath = $true; break }
    }
    if (-not $onPath) {
        Write-Warning "$binDir is not on PATH - add to ~/.zshrc:  export PATH=`"`$HOME/.local/bin:`$PATH`""
    }
}

# 5) the profile block above is the whole point of this installer, and a
# Restricted / AllSigned policy makes PowerShell skip the profile silently -
# the user would just find `preheat` "not recognized" with nothing to go on
if (-not $OnMac) {
    # a bare Get-ExecutionPolicy reports the EFFECTIVE policy, which inside a
    # `-ExecutionPolicy Bypass` launch is Bypass even while every persisted
    # scope says Restricted - and the user's next normal window then skips the
    # profile. Read the persisted scopes in precedence order instead.
    try {
        $pol = 'Undefined'
        $scopes = @{}
        foreach ($e in @(Get-ExecutionPolicy -List)) { $scopes[[string]$e.Scope] = [string]$e.ExecutionPolicy }
        foreach ($s in @('MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine')) {
            if ($scopes[$s] -and $scopes[$s] -ne 'Undefined') { $pol = $scopes[$s]; break }
        }
        if (@('Restricted', 'AllSigned', 'Undefined') -contains $pol) {
            Write-Warning "Persisted execution policy is '$pol' (a Windows client treats Undefined as Restricted) - a normal PowerShell window will not load your profile, so the preheat / claude-panel functions will not exist there. Fix: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
        }
    } catch { }
}

# 6) Codex (beta): one informational line - finding it changes nothing, a
# "codex" section in schedule.json is what turns Codex preheat on. Looking
# never runs codex, and a broken codex.ps1 must not fail the install.
$codexExe = $null
try {
    . (Join-Path $repoDir 'codex.ps1')
    $codexExe = Resolve-CodexExe
} catch { }
if ($codexExe) {
    Write-Host ("[info] Codex found ({0}) - see preheat status -Codex" -f $codexExe.kind)
} else {
    Write-Host "[info] Codex not found - Codex preheat stays off"
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Edit schedule.json to your own weekly rules"
Write-Host "  2. Reload profile: . '$profilePath'   (or open a new terminal)"
Write-Host "  3. Run: preheat apply"
Write-Host "  4. Run: claude-panel   (opens the local status page)"
Write-Host "  Optional: preheat statusline on   (feeds the panel's live quota strip)"
