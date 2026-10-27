#Requires -Version 5.1
<#
codex.ps1 -- OpenAI Codex adapter for claude-preheat. Dot-sourced by preheat.ps1
after platform.ps1 (needs Get-ClaudeHome, Quote-Arg, $OnMac); never run directly.

Two kinds of child process, nothing else:
  codex app-server --stdio   read-only quota reads over JSON-RPC. Private pipe,
                             our own child: never `daemon` or `proxy`, which
                             attach to the instance the desktop app shares.
                             Only the four methods in $CodexAllowedMethods ever
                             reach the wire.
  codex exec ...             the ping that spends quota. Read-only sandbox,
                             ephemeral, the user's config/rules ignored, an
                             empty working dir, hooks/plugins off.

Windows are told apart by windowDurationMins only, never by the
primary/secondary slot: a free account puts its 30-day window in `primary`.
An idle window does not report resetsAt = null - it answers "if you started
now", sliding forward with the clock. A running window freezes at its end.
Ignition therefore looks like SLIDING -> FROZEN (proven on a free account's
30-day window by codex-probe).

Pure functions take plain data and never touch the clock, disk or processes;
the epoch they judge against is passed in.
#>

$CodexRoot = $PSScriptRoot
$CodexAllowedMethods = @('initialize', 'initialized', 'account/read', 'account/rateLimits/read')
# -c, not a `codex features list` intersection: that command reaches cloud
# config. An unknown feature key only logs a warning upstream, so the same
# list is safe on every version, and a -c layer still applies under
# --ignore-user-config.
$CodexFeatureFlags = @(
    '-c', 'features.hooks=false', '-c', 'features.memories=false', '-c', 'features.goals=false',
    '-c', 'features.apps=false', '-c', 'features.plugins=false'
)
$CodexPassthroughKeys = @('cli_auth_credentials_store', 'forced_login_method', 'forced_chatgpt_workspace_id', 'chatgpt_base_url')

function Get-CodexProp($Obj, [string]$Name, $Default = $null) {
    # the backend omits fields rather than nulling them (a free account has no
    # secondary window, a workspace login has no email): missing reads as
    # $Default. Hashtables first - their keys are not PSObject properties.
    if ($null -eq $Obj) { return $Default }
    if ($Obj -is [System.Collections.IDictionary]) {
        if (-not $Obj.Contains($Name)) { return $Default }
        $v = $Obj[$Name]
    } else {
        $p = $Obj.PSObject.Properties[$Name]
        if ($null -eq $p) { return $Default }
        $v = $p.Value
    }
    if ($null -eq $v) { return $Default }
    $v
}

function Get-CodexEpoch {
    [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function Stop-CodexTree($Proc) {
    # the tree-kill overload of Kill is .NET Core only, and a plain Kill() leaves the
    # grandchildren (a .cmd launcher's shell, exec's helpers) holding our
    # pipes. Never throws.
    $ErrorActionPreference = 'Continue'   # taskkill's stderr must not throw under the caller's Stop
    if (-not $Proc) { return }
    try { if ($Proc.HasExited) { return } } catch { return }
    if (-not $OnMac) {
        try { & taskkill.exe /T /F /PID $Proc.Id 2>&1 | Out-Null } catch { }
    } else {
        # exec's sandbox/tool children and app-server's helpers: best effort,
        # one level is all a directly started codex binary has
        try { & pkill -TERM -P $Proc.Id 2>&1 | Out-Null } catch { }
    }
    try { if (-not $Proc.HasExited) { $Proc.Kill() } } catch { }
    try { [void]$Proc.WaitForExit(3000) } catch { }
}

# ---------- finding codex ----------

function Get-CodexHome {
    if ($env:CODEX_HOME) { return $env:CODEX_HOME }
    Join-Path (Get-ClaudeHome) '.codex'
}

function Get-CodexCandidates([switch]$First) {
    # every place an install leaves a runnable codex, in the order of design
    # appendix A. Looked up on every call, never cached: the desktop app
    # updates itself into a new hash dir, and a baked path would go stale.
    # Fixed relative paths only (no recursive search over npm roots - slow at
    # fire time), except inside one IDE extension's bin dir. -First stops at
    # the first hit (Resolve-CodexExe; spares the Appx query).
    $onWin = -not $OnMac
    $leaf = if ($onWin) { 'codex.exe' } else { 'codex' }
    $codexHome = Get-CodexHome
    $userHome = Get-ClaudeHome
    $shims = @(Get-Command 'codex' -CommandType Application -All -ErrorAction SilentlyContinue)
    $out = New-Object System.Collections.ArrayList
    $seen = @{}

    $steps = @(
        @{ kind = 'env'; find = { if ($env:PREHEAT_CODEX_EXE) { $env:PREHEAT_CODEX_EXE } } },
        @{ kind = 'path'; find = {
            foreach ($s in $shims) {
                $src = $s.Source
                if ($onWin) { if ($src -match '\.exe$') { $src } }
                else {
                    # npm's bin on macOS is a symlink to a node script: that
                    # one is the npm step's to dig through
                    $t = $null
                    try { $t = (Get-Item $src -ErrorAction SilentlyContinue).Target } catch { }
                    if (-not ("$t" -match '\.js$')) { $src }
                }
            } } },
        @{ kind = 'npm'; find = {
            $roots = @()
            foreach ($s in $shims) {
                $d = Split-Path $s.Source -Parent
                if ($onWin) { $roots += (Join-Path $d 'node_modules') }
                else { $roots += [System.IO.Path]::Combine([string[]]@((Split-Path $d -Parent), 'lib', 'node_modules')) }
            }
            if ($onWin) {
                if ($env:APPDATA) { $roots += [System.IO.Path]::Combine([string[]]@($env:APPDATA, 'npm', 'node_modules')) }
                $plats = @(@('codex-win32-x64', 'x86_64-pc-windows-msvc'), @('codex-win32-arm64', 'aarch64-pc-windows-msvc'))
            } else {
                $roots += @('/usr/local/lib/node_modules', '/opt/homebrew/lib/node_modules',
                            [System.IO.Path]::Combine([string[]]@($userHome, '.npm-global', 'lib', 'node_modules')))
                $plats = @(@('codex-darwin-arm64', 'aarch64-apple-darwin'), @('codex-darwin-x64', 'x86_64-apple-darwin'))
            }
            foreach ($r in $roots) {
                foreach ($pl in $plats) {
                    # nested (verified, 0.162.1) and hoisted npm layouts
                    [System.IO.Path]::Combine([string[]]@($r, '@openai', 'codex', 'node_modules', '@openai', $pl[0], 'vendor', $pl[1], 'bin', $leaf))
                    [System.IO.Path]::Combine([string[]]@($r, '@openai', $pl[0], 'vendor', $pl[1], 'bin', $leaf))
                }
            } } },
        # current is a junction the installer swaps on update: a stable path
        @{ kind = 'standalone'; find = { [System.IO.Path]::Combine([string[]]@($codexHome, 'packages', 'standalone', 'current', 'bin', $leaf)) } },
        @{ kind = 'daemon'; find = { [System.IO.Path]::Combine([string[]]@($codexHome, 'packages', 'app-server-daemon', 'current', 'bin', $leaf)) } },
        @{ kind = 'appx'; find = {
            if ($onWin -and (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
                try {
                    @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue -WarningAction SilentlyContinue) |
                        Sort-Object { [version]$_.Version } -Descending |
                        ForEach-Object { [System.IO.Path]::Combine([string[]]@($_.InstallLocation, 'app', 'resources', 'codex.exe')) }
                } catch { }
            } } },
        @{ kind = 'appbin'; find = {
            # the desktop app's own copy, one hash dir per build: newest first
            if ($onWin -and $env:LOCALAPPDATA) {
                @(Get-ChildItem -Path ([System.IO.Path]::Combine([string[]]@($env:LOCALAPPDATA, 'OpenAI', 'Codex', 'bin'))) -Filter 'codex.exe' -Recurse -Depth 1 -File -ErrorAction SilentlyContinue) |
                    Sort-Object LastWriteTimeUtc -Descending | ForEach-Object { $_.FullName }
            } } },
        @{ kind = 'macapp'; find = {
            # Codex.app may have been migrated to ChatGPT.app, and both can
            # coexist with a stale copy (openai/codex#48052): newest first
            if (-not $onWin) {
                $hits = foreach ($dir in @('/Applications', (Join-Path $userHome 'Applications'))) {
                    foreach ($app in @('Codex.app', 'ChatGPT.app')) {
                        $f = [System.IO.Path]::Combine([string[]]@($dir, $app, 'Contents', 'Resources', 'codex'))
                        if (Test-Path -LiteralPath $f -PathType Leaf) { Get-Item -LiteralPath $f }
                    }
                }
                @($hits) | Where-Object { $_ } | Sort-Object LastWriteTimeUtc -Descending | ForEach-Object { $_.FullName }
            } } },
        @{ kind = 'ide'; find = {
            # unverified layout (beta collects it): any codex binary under the
            # newest openai.chatgpt extension's bin dir
            $exts = foreach ($d in @(Get-ChildItem -Path $userHome -Directory -Force -ErrorAction SilentlyContinue |
                                     Where-Object { $_.Name -like '.vscode*' -or $_.Name -eq '.cursor' })) {
                Get-ChildItem -Path (Join-Path $d.FullName 'extensions') -Directory -Filter 'openai.chatgpt-*' -ErrorAction SilentlyContinue
            }
            foreach ($e in @(@($exts) | Where-Object { $_ } | Sort-Object LastWriteTimeUtc -Descending)) {
                Get-ChildItem -Path (Join-Path $e.FullName 'bin') -Filter $leaf -Recurse -File -ErrorAction SilentlyContinue |
                    Select-Object -First 1 | ForEach-Object { $_.FullName }
            } } }
    )

    foreach ($step in $steps) {
        foreach ($p in @(& $step.find)) {
            if (-not $p) { continue }
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
            $key = [string]$p
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            [void]$out.Add(@{ path = $key; kind = $step.kind })
            if ($First) { return $out.ToArray() }
        }
    }
    $out.ToArray()
}

function Resolve-CodexExe {
    # -> @{ path; kind } | $null. Kind, never the path, goes to the journal.
    $c = @(Get-CodexCandidates -First)
    if ($c.Count) { return $c[0] }
    $null
}

function Get-CodexConfigPassthrough([string]$CodexHome) {
    # --ignore-user-config keeps the user's config.toml away from the ping,
    # but a few top-level keys decide WHICH login exec uses (keyring storage,
    # a forced workspace). Without them the pre-read is signed in and the ping
    # is not. Copied verbatim as TOML values; a line regex is enough for
    # top-level scalars. -> @('-c','key=value', ...)
    if (-not $CodexHome) { $CodexHome = Get-CodexHome }
    $f = Join-Path $CodexHome 'config.toml'
    $out = @()
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return $out }
    try { $lines = @(Get-Content -LiteralPath $f -Encoding UTF8 -ErrorAction Stop) } catch { return $out }
    foreach ($line in $lines) {
        if ($line -match '^\s*\[') { break }   # first table header: top level is over
        if ($line -notmatch '^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$') { continue }
        $key = $Matches[1]; $val = $Matches[2]
        if ($CodexPassthroughKeys -notcontains $key) { continue }
        if ($val -match '^("[^"]*"|''[^'']*'')') { $val = $Matches[1] }
        else { $val = ($val -replace '\s*#.*$', '') }
        if ($val) { $out += @('-c', ($key + '=' + $val)) }
    }
    $out
}

function Use-CodexEnvironment($Config, [switch]$KeepEnv) {
    # every codex child inherits these: the proxy (a mainland-China user
    # without TUN reads nothing without it) and the CODEX_HOME apply saw.
    # -KeepEnv (status/report, run from the user's shell): a CODEX_HOME set
    # right there wins over the remembered one, so status reads the account
    # the user's own codex uses.
    if (-not $Config) { return }
    $proxy = Get-CodexProp $Config 'proxy'
    if ($proxy) { $env:HTTPS_PROXY = $proxy; $env:HTTP_PROXY = $proxy }
    $h = Get-CodexProp (Get-CodexProp $Config 'codex') 'home'
    if ($h -and -not ($KeepEnv -and $env:CODEX_HOME)) { $env:CODEX_HOME = $h }
}

# ---------- app-server JSON-RPC (read-only) ----------

function Start-CodexRpcChild($Session) {
    # Open-CodexRpc and Reset-CodexRpc both come through here, so a restart
    # is literally the same code path as a first start.
    $argv = @('app-server', '--stdio')
    if ($Session.Flags) { $argv += $CodexFeatureFlags }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Session.Exe
    # one .Arguments string (the list form is .NET Core only); Quote-Arg applies the
    # Windows argv rules, which .NET also uses to split it on macOS
    $psi.Arguments = (@($argv | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.EnvironmentVariables['RUST_LOG'] = 'off'
    # .NET Framework opens the child's stdin with Console.InputEncoding and
    # flushes its preamble at once: under chcp 65001 that is a BOM glued to
    # our first JSON line. 5.1 cannot set a stdin encoding, so hand it a
    # preamble-free encoding for the duration of Start.
    $prevIn = $null
    try { if ([Console]::InputEncoding.GetPreamble().Length -gt 0) { $prevIn = [Console]::InputEncoding; [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false) } } catch { $prevIn = $null }
    try { $proc = [System.Diagnostics.Process]::Start($psi) }
    finally { if ($prevIn) { try { [Console]::InputEncoding = $prevIn } catch { } } }
    $Session.Proc = $proc
    $w = New-Object System.IO.StreamWriter($proc.StandardInput.BaseStream, (New-Object System.Text.UTF8Encoding($false)))
    $w.NewLine = "`n"
    $w.AutoFlush = $true
    $Session.In = $w
    $Session.Err = $proc.StandardError.ReadToEndAsync()
    $Session.NextId = 0
    $null = Invoke-CodexRpc $Session 'initialize' @{ clientInfo = @{ name = 'claude_preheat'; title = 'claude-preheat'; version = '0.7.0' } }
    $null = Invoke-CodexRpc $Session 'initialized' $null -Notification
}

function Open-CodexRpc([string]$Exe, [int]$TimeoutSec = 30) {
    # Restarting stays set through the handshake: a first start that hangs
    # fails once, instead of restarting into a second full timeout
    $s = [pscustomobject]@{ Exe = $Exe; Proc = $null; In = $null; Err = $null; NextId = 0; TimeoutSec = $TimeoutSec; Flags = $true; Restarting = $true }
    try { Start-CodexRpcChild $s }
    catch {
        # an older app-server that rejects -c exits before it answers:
        # once more without the feature flags, then give up
        if ("$($_.Exception.Message)" -notmatch 'closed the pipe') { Close-CodexRpc $s; throw }
        Close-CodexRpc $s
        $s.Flags = $false
        try { Start-CodexRpcChild $s } catch { Close-CodexRpc $s; throw }
    }
    $s.Restarting = $false
    $s
}

function Reset-CodexRpc($Session) {
    # a timed-out call leaves a ReadLineAsync parked on the old pipe, and it
    # would swallow the NEXT reply - every later call would read someone
    # else's answer. Killing the child retires it; the session object stays.
    if ($Session.Restarting) { return }
    $Session.Restarting = $true
    try {
        Stop-CodexTree $Session.Proc
        Start-CodexRpcChild $Session
    } finally { $Session.Restarting = $false }
}

function Invoke-CodexRpc($Session, [string]$Method, $Params, [switch]$Notification) {
    # hard gate, before anything is written: account/rateLimitResetCredit/consume
    # (spends a banked reset credit) can never get past this line
    if ($CodexAllowedMethods -notcontains $Method) { throw "BLOCKED $Method" }
    $msg = [ordered]@{}
    if (-not $Notification) { $Session.NextId++; $msg['id'] = $Session.NextId }
    $msg['method'] = $Method
    if ($null -ne $Params) { $msg['params'] = $Params }
    $Session.In.WriteLine((ConvertTo-Json -InputObject $msg -Depth 10 -Compress))
    if ($Notification) { return $null }
    $wanted = $msg['id']

    $deadline = [datetime]::UtcNow.AddSeconds($Session.TimeoutSec)
    while ([datetime]::UtcNow -lt $deadline) {
        $task = $Session.Proc.StandardOutput.ReadLineAsync()
        $left = [int][Math]::Max(1, ($deadline - [datetime]::UtcNow).TotalMilliseconds)
        if (-not $task.Wait($left)) { break }
        $line = $task.Result
        if ($null -eq $line) {
            $tail = ''
            try { if ($Session.Err.Wait(2000)) { $tail = [string]$Session.Err.Result } } catch { }
            if ($tail.Length -gt 300) { $tail = $tail.Substring($tail.Length - 300) }
            throw ("app-server closed the pipe during $Method. stderr: " + $tail.Trim())
        }
        if (-not $line.Trim()) { continue }
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        $id = Get-CodexProp $obj 'id'
        if (($null -ne $id) -and ("$id" -eq "$wanted")) {
            $e = Get-CodexProp $obj 'error'
            if ($null -ne $e) { throw ("RPC $Method failed: " + (ConvertTo-Json -InputObject $e -Depth 5 -Compress)) }
            return (Get-CodexProp $obj 'result')
        }
        # anything else is a server notification: not ours to act on
    }
    if (-not $Session.Restarting) { try { Reset-CodexRpc $Session } catch { } }
    throw "RPC $Method timed out after $($Session.TimeoutSec)s"
}

function Close-CodexRpc($Session) {
    # closing stdin is app-server's cue to exit; whatever is still alive
    # after 3s goes, children included. Never throws.
    if (-not $Session -or -not $Session.Proc) { return }
    try { $Session.In.Close() } catch { }
    try { if (-not $Session.Proc.WaitForExit(3000)) { Stop-CodexTree $Session.Proc } } catch { Stop-CodexTree $Session.Proc }
}

function Get-CodexShortHash([string]$Value) {
    if (-not $Value) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
        return ([System.BitConverter]::ToString($h) -replace '-', '').Substring(0, 8).ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-CodexRpcErrorKind([string]$Text) {
    # an API-key login has no ChatGPT plan and so no 5h window: that is not
    # "please sign in again"
    if ($Text -match 'chatgpt authentication required') { return 'apikey' }
    if ((Get-CodexFailureKind $Text 1) -eq 'auth') { return 'auth' }
    'other'
}

function Read-CodexQuota([string]$Exe, [int]$Reads = 1, [int]$IntervalSec = 30, [int]$TimeoutSec = 30) {
    # one fresh app-server per call, closed before returning: a child started
    # after a token refresh reads the rotated auth.json, and nothing runs in
    # parallel with the ping. account/read with refreshToken:false - no extra
    # refresh of our own (rateLimits/read may still refresh a token that is
    # about to expire; that is upstream's and out of our hands).
    $res = @{ ok = $false; kind = $null; err = $null; account = $null; reads = @() }
    $s = $null
    $email = $null; $accountId = $null
    try {
        $s = Open-CodexRpc $Exe $TimeoutSec
        $acct = Get-CodexProp (Invoke-CodexRpc $s 'account/read' @{ refreshToken = $false }) 'account'
        if (-not $acct) { $res.kind = 'auth'; $res.err = 'codex is not signed in'; return $res }
        $email = Get-CodexProp $acct 'email'
        $type = [string](Get-CodexProp $acct 'type' '')
        $res.account = @{ type = $type; plan = (Get-CodexProp $acct 'planType'); emailMasked = (Get-MaskedEmail $email); hash = $null }
        if ($type -match '^api') { $res.kind = 'apikey'; $res.err = 'codex is signed in with an API key'; return $res }
        # not $reads: PowerShell names are case-insensitive, that IS [int]$Reads
        $got = @()
        for ($i = 0; $i -lt $Reads; $i++) {
            if ($i -gt 0) { Start-Sleep -Seconds $IntervalSec }
            try {
                $rl = Invoke-CodexRpc $s 'account/rateLimits/read' @{ excludeResetCreditDetails = $true }
                # stamped AFTER the read: a slow round trip must not inflate
                # every remaining-time figure by exactly the drift we look for
                $got += , @{ epoch = (Get-CodexEpoch); raw = $rl }
                if (-not $accountId) { $accountId = Get-CodexProp $rl 'accountId' }
            } catch {
                $m = "$($_.Exception.Message)"
                $res.err = $m
                $k = Get-CodexRpcErrorKind $m
                if ($k -ne 'other') { $res.kind = $k; break }
            }
        }
        $res.reads = $got
        if (-not $res.kind) {
            if ($got.Count) { $res.ok = $true } else { $res.kind = 'other' }
        }
    } catch {
        $m = "$($_.Exception.Message)"
        $res.err = $m
        $res.kind = Get-CodexRpcErrorKind $m
    } finally {
        Close-CodexRpc $s
        if ($res.account) {
            $res.account.hash = Get-CodexShortHash $(if ($accountId) { [string]$accountId } else { [string]$email })
            if ((-not $res.account.plan) -and @($res.reads).Count) { $res.account.plan = (Get-CodexWindows $res.reads[0].raw).plan }
        }
        if ($res.err -and $res.err.Length -gt 400) { $res.err = $res.err.Substring(0, 400) }
    }
    $res
}

# ---------- judging windows (pure) ----------

function Test-CodexWindowMins($Mins, [int]$Target) {
    # +-7%, floor 2 min: 302 is the 5h window, 10080 the week
    if ($null -eq $Mins) { return $false }
    [Math]::Abs([double]$Mins - $Target) -le [Math]::Max(2, [Math]::Floor($Target * 0.07))
}

function Get-CodexWindows($RateLimits) {
    # rateLimits response -> the 5h and weekly windows of the `codex` bucket
    # (the main one; Spark and friends carry 5h windows of their own, and
    # anchoring one of those is not what the user asked for), falling back to
    # the single-bucket view older binaries return. `all` keeps every window
    # of every bucket for the journal: if a ping lights the wrong bucket, the
    # beta logs show it.
    $out = @{ plan = $null; bucket = $null; reached = $null; five = $null; weekly = $null; all = @() }
    if (-not $RateLimits) { return $out }
    $buckets = @()
    $byId = Get-CodexProp $RateLimits 'rateLimitsByLimitId'
    $byIdNames = @()
    if ($byId) {
        # foreach + `+= ,` rather than a pipeline: a one-bucket pipeline result
        # unrolls inside @() into ('codex', obj) and the bucket is lost
        $pairs = @()
        if ($byId -is [System.Collections.IDictionary]) { foreach ($k in @($byId.Keys)) { $pairs += , @($k, $byId[$k]) } }
        else { foreach ($pp in @($byId.PSObject.Properties)) { $pairs += , @($pp.Name, $pp.Value) } }
        foreach ($pr in $pairs) { if ($pr[1]) { $buckets += , @([string]$pr[0], $pr[1]); $byIdNames += [string]$pr[0] } }
    }
    $def = Get-CodexProp $RateLimits 'rateLimits'
    $defName = [string](Get-CodexProp $def 'limitId' 'default')
    if ($def -and ($byIdNames -notcontains $defName)) { $buckets += , @($defName, $def) }

    $main = $null; $mainName = $null
    foreach ($b in $buckets) { if ($b[0] -eq 'codex') { $mainName = $b[0]; $main = $b[1] } }
    if (-not $main -and $def) { $mainName = $defName; $main = $def }

    $all = @()
    foreach ($b in $buckets) {
        foreach ($slot in @('primary', 'secondary')) {
            $w = Get-CodexProp $b[1] $slot
            if (-not $w) { continue }
            $r = Get-CodexProp $w 'resetsAt'
            $all += , @{ bucket = $b[0]; mins = (Get-CodexProp $w 'windowDurationMins'); used = (Get-CodexProp $w 'usedPercent')
                         resetsAt = $(if ($null -ne $r) { [long]$r } else { $null }) }
        }
    }
    $out.all = $all
    if ($main) {
        $out.plan = Get-CodexProp $main 'planType'
        $out.bucket = $mainName
        $out.reached = Get-CodexProp $main 'rateLimitReachedType'
        foreach ($w in @($all | Where-Object { $_.bucket -eq $mainName })) {
            $win = @{ used = $w.used; resetsAt = $w.resetsAt; mins = $w.mins }
            if ((-not $out.five) -and (Test-CodexWindowMins $w.mins 300)) { $out.five = $win }
            elseif ((-not $out.weekly) -and (Test-CodexWindowMins $w.mins 10080)) { $out.weekly = $win }
        }
    }
    $out
}

function Test-CodexNo5hPlan([string]$Plan) {
    # free/go/pro have no 5h window by OpenAI's own pricing page. Whole ids
    # only (pro_* counts as pro): a future 'prolite' must not skip silently.
    $Plan -match '^(free|go|pro)(_|$)'
}

function Get-CodexPreVerdict($Windows, [long]$NowEpoch) {
    # one read, judged by time left until the reset. Idle (null, past, or a
    # full window ahead) -> ping. Clearly running -> skip and let the chase
    # book reset + 2 min. The 10-minute band at the top keeps a local clock a
    # few minutes off from calling an idle window "running" - that mistake
    # costs a whole morning, while a wasted ping costs real quota. No 5h
    # window: free/go/pro have none by OpenAI's own pricing page; any other
    # plan pings anyway (do not lock a Plus user out on a missing field).
    $v = @{ action = 'ping'; resetsAt = $null; idleValue = $null; skewSec = $null; windowUnknown = $false; mins = $null }
    $five = $null
    if ($Windows) { $five = $Windows.five }
    if (-not $five) {
        $plan = ''
        if ($Windows -and $Windows.plan) { $plan = [string]$Windows.plan }
        if (Test-CodexNo5hPlan $plan) { $v.action = 'skip-no5h' } else { $v.windowUnknown = $true }
        return $v
    }
    $mins = 300
    if ($null -ne $five.mins) { $mins = [int]$five.mins }
    $v.mins = $mins
    $v.resetsAt = $five.resetsAt
    if ($null -eq $five.resetsAt) { return $v }
    $r = [long]$five.resetsAt - $NowEpoch
    $full = [long]$mins * 60
    if ($r -le 0) { return $v }
    # a 5h limit already hit: the window is running. Not rateLimitReachedType:
    # it names the bucket's limit, which may be the WEEK - that ping only
    # bounces (journaled as kind limit), it must not book a chase 5h out
    $hit = ($null -ne $five.used) -and ([double]$five.used -ge 100)
    if ($r -ge ($full - 600) -and -not $hit) {
        # idle: the server answered "now + window", so the gap to a full
        # window is the clock skew between us and it, measured for free
        $v.idleValue = [long]$five.resetsAt
        $v.skewSec = [long]$five.resetsAt - $NowEpoch - $full
        return $v
    }
    $v.action = 'skip-running'
    $v
}

function Test-CodexMetered($Pre, [long]$PreEpoch, $Windows, [long]$NowEpoch) {
    # PURE - asked before a retry: did the failed attempt meter after all?
    # A running window by the pre-verdict's own test says yes, but that test
    # misses the usual case: a window opened ~3 min ago still has more than
    # 290 min left. So after an idle pre-read, a reset that fell behind where
    # the idle one would have slid to by now also says yes (server numbers
    # only, like the post-verdict; not the 10-minute band). A blind pre-read
    # has nothing to compare with: the pre-verdict test alone.
    if ((Get-CodexPreVerdict $Windows $NowEpoch).action -eq 'skip-running') { return $true }
    if ((-not $Pre) -or ($null -eq $Pre.idleValue)) { return $false }
    if ((-not $Windows) -or (-not $Windows.five) -or ($null -eq $Windows.five.resetsAt)) { return $false }
    $el = $NowEpoch - $PreEpoch
    [long]$Windows.five.resetsAt -lt ([long]$Pre.idleValue + $el - [Math]::Max(6, 0.05 * $el))
}

function Get-CodexPostVerdict($Pre, [long]$PreEpoch, [long]$PingStart, [long]$PingEnd, $PostReads) {
    # did the ping anchor the window? Judged on server numbers: an idle
    # window read before the ping already says "now + 5h" in server time, so
    # the expected frozen end is that value plus the time that passed until
    # the ping - local clock skew cancels out. Without an idle read the
    # expectation falls back to the local clock with a wide 10-minute band.
    # A window may also open a while AFTER the ping returned (metering lag,
    # the beta's open question): a pair that slid and then froze between its
    # two reads shows that, and a frozen end up to the newest read's time
    # still counts as ours - nobody else starts a window within minutes of a
    # scheduled ping, and either way it now runs from about our time.
    # -> @{ state = anchored|moved|sliding|unknown; resetsAt; lagSec }
    # lagSec: seconds from the ping's end to the window's start when it
    # started after the ping (server-exact after an idle pre-read, else the
    # first frozen read's local time).
    $res = @{ state = 'unknown'; resetsAt = $null; lagSec = $null }
    $reads = @($PostReads)
    $n = $reads.Count
    if ($n -gt 0) {
        $lastFive = $reads[$n - 1].windows.five
        if ($lastFive) { $res.resetsAt = $lastFive.resetsAt }
    }
    $states = @{}
    $lastIdx = -1
    for ($i = 1; $i -lt $n; $i++) {
        $fa = $reads[$i - 1].windows.five; $fb = $reads[$i].windows.five
        if ((-not $fa) -or (-not $fb) -or ($null -eq $fa.resetsAt) -or ($null -eq $fb.resetsAt)) { continue }
        $d = [long]$fb.resetsAt - [long]$fa.resetsAt
        $el = [long]$reads[$i].epoch - [long]$reads[$i - 1].epoch
        $tol = [Math]::Max(6, 0.05 * $el)
        if ([Math]::Abs($d) -le 3) { $states[$i] = 'frozen'; $lastIdx = $i }
        elseif ([Math]::Abs($d - $el) -le $tol) { $states[$i] = 'sliding'; $lastIdx = $i }
        elseif (($d -gt 3) -and ($d -lt ($el - $tol))) { $states[$i] = 'started'; $lastIdx = $i }
    }
    if ($lastIdx -lt 0) { return $res }
    if ($states[$lastIdx] -eq 'sliding') {
        if ($lastIdx -eq $n - 1) { $res.state = 'sliding' }
        return $res
    }
    # frozen or started: the pair's newer read holds the frozen end
    $five = $reads[$lastIdx].windows.five
    $F = [long]$five.resetsAt
    $res.resetsAt = $F
    $mins = 300
    if ($null -ne $five.mins) { $mins = [int]$five.mins } elseif ($Pre -and $Pre.mins) { $mins = [int]$Pre.mins }
    $span = $PingEnd - $PingStart
    $idle = $Pre -and ($null -ne $Pre.idleValue)
    if ($idle) {
        $E = [long]$Pre.idleValue + ($PingStart - $PreEpoch)
        $band = 30
    } else {
        $E = $PingStart + [long]$mins * 60
        $band = 600
    }
    $lo = $E - $band; $hi = $E + $span + $band
    $late = $E + ([long]$reads[$lastIdx].epoch - $PingStart) + $band
    if ($F -lt $lo) { $res.state = 'moved'; return $res }
    if ($F -gt $late) { $res.state = 'unknown'; return $res }
    $res.state = 'anchored'
    # a lag only past the band (inside it the numbers are read noise), or
    # when a read still slid after the ping
    $sawStart = ($states[$lastIdx] -eq 'started') -or (($lastIdx -ge 2) -and ($states[$lastIdx - 1] -eq 'sliding'))
    if ($idle) {
        if (($F -gt $hi) -or $sawStart) { $res.lagSec = [Math]::Max(0, $F - ($E + $span)) }
    } elseif ($sawStart) {
        $first = $lastIdx
        if ($states[$lastIdx] -ne 'started') { $first = $lastIdx - 1 }
        $res.lagSec = [long]$reads[$first].epoch - $PingEnd
    }
    $res
}

function Format-CodexOtherWindows($Windows, [long]$NowEpoch) {
    # PURE - the 5h windows of every bucket but the main one, one string for
    # the journal ('codex_spark 3% in=17990s; ...'): if a ping lights another
    # bucket, the beta report shows it. Relative times only. $null = none.
    if (-not $Windows) { return $null }
    $parts = @()
    foreach ($w in @($Windows.all)) {
        if ((-not $w) -or ($w.bucket -eq $Windows.bucket) -or (-not (Test-CodexWindowMins $w.mins 300))) { continue }
        $s = '{0} {1}%' -f $w.bucket, $w.used
        if ($null -ne $w.resetsAt) { $s += (' in={0}s' -f ([long]$w.resetsAt - $NowEpoch)) }
        $parts += $s
    }
    if ($parts.Count -eq 0) { return $null }
    $parts -join '; '
}

# ---------- the ping (codex exec) ----------

function ConvertFrom-CodexExecStream([string]$Text) {
    # `codex exec --json` prints one event a line. The evidence that the
    # request reached the server is turn.completed with its usage: that is
    # what separates "not metered" from "never left the machine" (the stdin
    # hang, openai/codex#20919). Item type is agent_message upstream - the
    # probe looked for assistant_message and never saw a reply. Pure.
    $r = @{ threadId = $null; sawTokens = $false; tokens = @{ input = $null; cached = $null; output = $null; reasoning = $null }; agentText = $false; errors = @() }
    if (-not $Text) { return $r }
    foreach ($line in ($Text -split '\r?\n')) {
        $s = $line.Trim()
        if (-not $s.StartsWith('{')) { continue }
        # an event shape we did not expect must never cost the evidence: by
        # now the quota is spent
        if ($s -match '"type"\s*:\s*"turn\.completed"') { $r.sawTokens = $true }
        try { $ev = $s | ConvertFrom-Json } catch { continue }
        try {
            switch ([string](Get-CodexProp $ev 'type' '')) {
                'thread.started' { $r.threadId = Get-CodexProp $ev 'thread_id' }
                'turn.completed' {
                    $r.sawTokens = $true
                    $u = Get-CodexProp $ev 'usage'
                    $r.tokens = @{ input = (Get-CodexProp $u 'input_tokens'); cached = (Get-CodexProp $u 'cached_input_tokens')
                                   output = (Get-CodexProp $u 'output_tokens'); reasoning = (Get-CodexProp $u 'reasoning_output_tokens') }
                }
                'turn.failed' { $r.errors += [string](Get-CodexProp (Get-CodexProp $ev 'error') 'message' 'turn failed') }
                'error' { $r.errors += [string](Get-CodexProp $ev 'message' 'error event') }
                'item.completed' {
                    $item = Get-CodexProp $ev 'item'
                    $t = [string](Get-CodexProp $item 'type' '')
                    if ($t -eq 'agent_message' -and (Get-CodexProp $item 'text')) { $r.agentText = $true }
                    elseif ($t -eq 'error') { $r.errors += [string](Get-CodexProp $item 'message' 'error item') }
                }
            }
        } catch { }
    }
    $r
}

function Get-CodexFailureKind([string]$Text, [int]$Exit) {
    # auth and limit never heal within a retry: the caller stops on both.
    # usage-error = this binary does not know a flag we send (an old npm copy
    # shadowing a newer desktop one): try the next candidate. Pure.
    if (-not $Text) { return 'other' }
    if ($Text -match 'not logged in|login|unauthori|\b401\b|refresh_token_reused|token_invalidated|token expired') { return 'auth' }
    if ($Text -match 'usage limit|rate limit|limit reached') { return 'limit' }
    if (($Text -match 'unexpected argument|unrecognized') -or ($Text -cmatch '(?m)^\s*Usage:')) { return 'usage-error' }
    'other'
}

function Invoke-CodexProcess([string]$Exe, [string[]]$ArgList, [string]$WorkDir, [int]$TimeoutSec) {
    # one short-lived codex child: stdin from an empty file (at EOF from the
    # very first read - exec otherwise waits forever for "extra
    # instructions", openai/codex#20919), stdout/stderr to per-call files,
    # read back as UTF-8, tree-killed on timeout.
    $tag = '{0}-{1}' -f $PID, ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $inFile  = Join-Path $CodexRoot ('.codex-in-{0}.tmp' -f $tag)
    $outFile = Join-Path $CodexRoot ('.codex-out-{0}.tmp' -f $tag)
    $errFile = Join-Path $CodexRoot ('.codex-err-{0}.tmp' -f $tag)
    $r = @{ exit = $null; out = ''; err = ''; timedOut = $false; startEpoch = $null; endEpoch = $null; ms = $null }
    $prevLog = $env:RUST_LOG
    try {
        [System.IO.File]::WriteAllText($inFile, '')
        $sp = @{
            # Args = Start-Process's own alias, so the 7-only API guard stays a plain grep
            FilePath = $Exe; Args = (@($ArgList | ForEach-Object { Quote-Arg $_ }) -join ' ')
            RedirectStandardInput = $inFile; RedirectStandardOutput = $outFile; RedirectStandardError = $errFile; PassThru = $true
        }
        if ($WorkDir) { $sp.WorkingDirectory = $WorkDir }
        if (-not $OnMac) { $sp.WindowStyle = 'Hidden' }
        $env:RUST_LOG = 'off'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r.startEpoch = Get-CodexEpoch
        $p = Start-Process @sp
        $null = $p.Handle   # PS 5.1: without touching Handle first, ExitCode reads null forever
        if ($p.WaitForExit($TimeoutSec * 1000)) { $r.exit = $p.ExitCode }
        else { $r.timedOut = $true; Stop-CodexTree $p }
        $sw.Stop()
        $r.ms = [long]$sw.ElapsedMilliseconds
        $r.endEpoch = Get-CodexEpoch
        foreach ($k in @('out', 'err')) {
            $f = if ($k -eq 'out') { $outFile } else { $errFile }
            if (Test-Path -LiteralPath $f) {
                # BOM-less UTF-8: 5.1 would read it in the ANSI code page
                $t = Get-Content -LiteralPath $f -Raw -Encoding UTF8
                if ($null -ne $t) { $r[$k] = $t }
            }
        }
    } finally {
        $env:RUST_LOG = $prevLog
        Remove-Item -LiteralPath $inFile, $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
    $r
}

function Invoke-CodexPing([string]$Exe, [string]$WorkDir, [string[]]$ExtraArgs, [int]$TimeoutSec = 120) {
    # the one call that spends quota. No -m and no effort: the account's
    # default model meters the bucket the user works in.
    if ($WorkDir -and -not (Test-Path -LiteralPath $WorkDir)) {
        New-Item -ItemType Directory -Path $WorkDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $argv = @('exec', '--ephemeral', '--skip-git-repo-check', '--ignore-user-config', '--ignore-rules',
              '-s', 'read-only', '-C', $WorkDir, '--color', 'never', '--json') + $CodexFeatureFlags
    if ($ExtraArgs) { $argv += $ExtraArgs }
    $argv += 'Reply with exactly: hi'
    $res = @{ ok = $false; exit = $null; kind = $null; err = $null; stream = (ConvertFrom-CodexExecStream ''); ms = $null; startEpoch = $null; endEpoch = $null }
    try {
        $p = Invoke-CodexProcess $Exe $argv $WorkDir $TimeoutSec
    } catch {
        $res.kind = 'other'; $res.err = "$($_.Exception.Message)"
        if ($res.err.Length -gt 400) { $res.err = $res.err.Substring(0, 400) }
        return $res
    }
    $res.exit = $p.exit; $res.ms = $p.ms; $res.startEpoch = $p.startEpoch; $res.endEpoch = $p.endEpoch
    $res.stream = ConvertFrom-CodexExecStream $p.out
    $text = ((@($res.stream.errors) + @($p.err.Trim())) | Where-Object { $_ }) -join ' | '
    if ($p.timedOut) {
        $res.kind = 'other'; $text = ("timeout after {0}s" -f $TimeoutSec) + $(if ($text) { ' | ' + $text } else { '' })
    } elseif (($p.exit -eq 0) -and $res.stream.sawTokens) {
        $res.ok = $true
    } else {
        $res.kind = Get-CodexFailureKind $text ([int]$p.exit)
        if (-not $text) { $text = $(if ($p.exit -eq 0) { 'exit 0 but no token event: the request may never have been sent' } else { "exit $($p.exit)" }) }
    }
    if (-not $res.ok) {
        if ($text.Length -gt 400) { $text = $text.Substring(0, 400) }
        $res.err = $text
    }
    $res
}

function Get-CodexVersion([string]$Exe) {
    # 'codex-cli 0.162.1' -> '0.162.1'; $null when it does not answer in 10s
    if (-not $Exe) { return $null }
    try {
        $p = Invoke-CodexProcess $Exe @('--version') $CodexRoot 10
        if ($p.timedOut -or $p.exit -ne 0) { return $null }
        $line = (@($p.out -split '\r?\n' | Where-Object { $_.Trim() }) | Select-Object -First 1)
        if (-not $line) { return $null }
        if ($line -match '(\d+\.\d+\.\d+[0-9A-Za-z.+-]*)') { return $Matches[1] }
        return $line.Trim()
    } catch { return $null }
}

# ---------- cache and redaction ----------

function Write-CodexCache($Path, $Quota, $Windows, [string]$Source) {
    # state-ratelimits-codex.json: the panel's Codex quota strip. Its own file -
    # the statusline tap rewrites state-ratelimits.json wholesale. Same shape
    # as the Claude cache (five_hour / seven_day, used_percentage + resets_at
    # in epoch seconds) so the panel renders both with one function; an
    # absent window is omitted. temp + replace like Write-RateLimitCache.
    # Telemetry: never throws.
    $tmp = $null
    try {
        if (-not $Path) { $Path = Join-Path $CodexRoot 'state-ratelimits-codex.json' }
        $tmp = $Path + '.tmp-' + $PID
        $acct = $null
        if ($Quota) { $acct = $Quota.account }
        $plan = Get-CodexProp $acct 'plan'
        if ((-not $plan) -and $Windows) { $plan = $Windows.plan }
        $rl = [ordered]@{}
        $five = $null; $week = $null
        if ($Windows) { $five = $Windows.five; $week = $Windows.weekly }
        if ($five) { $rl.five_hour = [ordered]@{ used_percentage = $five.used; resets_at = $five.resetsAt } }
        if ($week) { $rl.seven_day = [ordered]@{ used_percentage = $week.used; resets_at = $week.resetsAt } }
        $obj = [ordered]@{
            capturedAt     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
            source         = $Source
            plan           = $plan
            account        = [ordered]@{ emailMasked = (Get-CodexProp $acct 'emailMasked'); hash = (Get-CodexProp $acct 'hash') }
            has5h          = [bool]$five
            window_minutes = $(if ($five) { $five.mins } else { $null })
            rate_limits    = $rl
        }
        $text = ConvertTo-Json -InputObject $obj -Compress -Depth 6
        [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
        for ($n = 1; $n -le 2; $n++) {
            try {
                if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($tmp, $Path, [NullString]::Value) }
                else { [System.IO.File]::Move($tmp, $Path) }
                break
            } catch {
                if ($n -ge 2) { throw }
                Start-Sleep -Milliseconds 50
            }
        }
    } catch {
        if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-MaskedEmail([string]$Email) {
    # 'alice@example.com' -> 'a***@example.com'. Pure.
    if ($Email -notmatch '^\s*([^@\s])[^@\s]*@([^@\s]+)\s*$') { return $null }
    $Matches[1] + '***@' + $Matches[2]
}

function Protect-ReportText([string]$Text) {
    # everything `report -Codex` prints goes through here. Redact, never
    # refuse: one stray email inside an error string must not cost the tester
    # the whole paste-back. The home path covers its plain, forward-slash and
    # JSON-escaped forms; the user name only on word boundaries, only from 4
    # characters up, and an all-digit one only as a path segment - an
    # unbounded replace once rewrote epochs that happened to contain a 5-digit
    # user name.
    if (-not $Text) { return $Text }
    $out = $Text
    $out = [regex]::Replace($out, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<email>')
    $out = [regex]::Replace($out, 'eyJ[A-Za-z0-9_-]{10,}(\.[A-Za-z0-9_-]+){0,2}', '<jwt>')
    $out = [regex]::Replace($out, 'sk-[A-Za-z0-9_-]{8,}', '<key>')
    # temp first (an 8.3 short form of the home lives there) and a CODEX_HOME
    # outside the home; then the home itself
    $paths = @()
    try { $paths += , @([System.IO.Path]::GetTempPath(), '<temp>') } catch { }
    if ($env:CODEX_HOME) { $paths += , @($env:CODEX_HOME, '<codex-home>') }
    try { $paths += , @((Get-ClaudeHome), '~') } catch { }
    if ($HOME) { $paths += , @($HOME, '~') }
    foreach ($pp in $paths) {
        $h = ([string]$pp[0]).TrimEnd('\', '/')
        if ($h.Length -lt 3) { continue }
        foreach ($form in @(($h -replace '\\', '\\'), $h, ($h -replace '\\', '/'), ($h -replace '/', '\'))) {
            $out = [regex]::Replace($out, [regex]::Escape($form), $pp[1], 'IgnoreCase')
        }
    }
    foreach ($u in @($env:USERNAME, $env:USER)) {
        if ((-not $u) -or $u.Length -lt 4) { continue }
        # an all-digit name would eat ordinary numbers (ms=, drift_s=): only
        # as a path segment
        if ($u -match '^\d+$') {
            $out = [regex]::Replace($out, '(?<=[\\/])' + [regex]::Escape($u) + '(?![A-Za-z0-9])', '<user>')
            continue
        }
        $out = [regex]::Replace($out, '(?<![A-Za-z0-9])' + [regex]::Escape($u) + '(?![A-Za-z0-9])', '<user>', 'IgnoreCase')
    }
    $out
}
