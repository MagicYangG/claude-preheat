#Requires -Version 5.1
<#
claude-preheat panel -- local web control panel

Pure PowerShell HttpListener server that serves web/index.html and implements
the JSON API the page talks to. It owns no state of its own: every read/write
goes through preheat.ps1 (single source of truth) so the CLI and the web
panel can never disagree.

Usage: panel.ps1 [-Port 7878] [-NoBrowser]

Endpoints (see web/index.html for the client side):
  GET  /                     web/index.html
  GET  /api/status           {preheat:{tasks}}
  GET  /api/schedule         {rules:[...], mtime:"<ticks>"} - rules only, so a
                             stale tab can never write back a proxy/_readme it
                             read hours ago; mtime is the optimistic-lock token
  GET  /api/ratelimits       cached usage windows written by statusline-tap.cjs
  GET  /api/learn            30-day rhythm + 7-day window-utilization report
  POST /api/preheat/once     {kind:"reset"|"at"|"plus", value:"HH:mm"|"2h"}
  POST /api/preheat/apply    {rules:[{days:[...], reset:"HH:mm"}, ...], baseMtime?}
                             409 {code:"stale"} when the file moved under the tab

Ctrl+C stops the listener cleanly (polling GetContextAsync, not a blocking
GetContext, so the console break can actually land).
#>
[CmdletBinding()]
param(
    [int]$Port = 7878,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
# the panel is often started from inside a Claude Code session, whose shells
# carry CLAUDE_CODE_CHILD_SESSION=1 - the claude pings preheat.ps1 spawns
# below us would inherit it and silently stop saving transcripts. Scrub it
# once so no descendant can ever be marked.
Remove-Item Env:CLAUDE_CODE_CHILD_SESSION -ErrorAction SilentlyContinue
$Root         = $PSScriptRoot
$WebDir       = Join-Path $Root 'web'
$IndexPath    = Join-Path $WebDir 'index.html'
$PreheatScript = Join-Path $Root 'preheat.ps1'
$PanelLog     = Join-Path $Root 'panel-log.txt'
$ConfigPath   = Join-Path $Root 'schedule.json'

# OS adapter: job listing (Task Scheduler / launchd), host-shell resolution
. (Join-Path $Root 'platform.ps1')

# preheat.ps1's read-only helpers (Get-HistoryTimestamps / Get-LearnReport) run
# in-process for /api/learn - a shelled-out learn blocked this single-threaded
# listener for seconds on every cache miss. '__selftest__' falls through to the
# usage branch, whose one Write-Host the 6>$null swallows; the script's own
# $Root/$ConfigPath are re-set to the same values we already have.
try { . $PreheatScript '__selftest__' 6>$null | Out-Null } catch { }
# the dot-source also lands preheat.ps1's param variables in this scope, one of
# them a [switch]-typed $Json - and PowerShell variable names are case-
# insensitive, so any later top-level `$json = ...` would hit that type
# constraint and throw. Drop them (and its $Command/$Arg) right away.
Remove-Variable -Name Json, Command, Arg -Scope Script -ErrorAction SilentlyContinue

# cache for the preheat-status read: it runs in-process, but each uncached
# poll is still a Get-ScheduledTask + Get-ScheduledTaskInfo query, so keep a
# short TTL
$script:PreheatStatusCache = @{ value = $null; ts = [datetime]::MinValue }
$PreheatStatusCacheTtlSec  = 30

# learn report scans ~30 days of prompt history in-process; long TTL, lazy
$script:LearnCache         = @{ value = $null; ts = [datetime]::MinValue }
$LearnCacheTtlSec          = 600

$Shell = Resolve-HostShell

function Write-PanelLog([string]$line) {
    $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    try {
        if ((Test-Path $PanelLog) -and ((Get-Item $PanelLog).Length -gt 2MB)) {
            $keep = Get-Content $PanelLog -Tail 1000 -Encoding UTF8
            Set-Content -Path $PanelLog -Value $keep -Encoding UTF8
        }
        Add-Content -Path $PanelLog -Value ('[{0}] {1}' -f $ts, $line) -Encoding UTF8
    } catch { }
}

# ---------- shelling out to preheat.ps1 ----------

function Quote-Arg([string]$a) {
    if ($a -notmatch '[\s"]') { return $a }
    # Windows argv rules: a backslash run is literal UNLESS it precedes a quote.
    # Escaping only the quote (" -> \") lets a value ending in \" splice extra
    # argv tokens into the child process - double every backslash run before a
    # quote (and before the closing quote), then escape the quote itself.
    $escaped = [regex]::Replace($a, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
    $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
    '"' + $escaped + '"'
}

function Invoke-BackendCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$CmdArgs = @()
    )
    $quoted = @($CmdArgs | ForEach-Object { Quote-Arg $_ })
    $argStr = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $ScriptPath, ($quoted -join ' ')
    $stamp   = [guid]::NewGuid().ToString('N')
    # the OS temp dir, not $Root: a killed panel used to leave .panel-*.tmp
    # litter inside the repo, where it shows up in git status forever
    $tmpDir  = [System.IO.Path]::GetTempPath()
    $outFile = Join-Path $tmpDir (".panel-out-$stamp.tmp")
    $errFile = Join-Path $tmpDir (".panel-err-$stamp.tmp")
    try {
        # no stdin redirect: every preheat.ps1 command invoked here is fully
        # specified by its argv, so nothing ever needs to read stdin
        $p = Start-Process -FilePath $Shell -ArgumentList $argStr -WorkingDirectory $Root `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
            -PassThru -NoNewWindow
        $null = $p.Handle   # PS 5.1: without touching Handle first, ExitCode reads null forever
        if (-not $p.WaitForExit(120000)) {
            try { $p.Kill() } catch { }
            return @{ ExitCode = -1; StdOut = ''; StdErr = 'timeout after 120s' }
        }
        $stdout = ''; if (Test-Path $outFile) { $stdout = Get-Content $outFile -Raw -Encoding UTF8 }
        $stderr = ''; if (Test-Path $errFile) { $stderr = Get-Content $errFile -Raw -Encoding UTF8 }
        @{ ExitCode = $p.ExitCode; StdOut = $stdout; StdErr = $stderr }
    } finally {
        Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
    }
}

function Get-ResultMessage($res) {
    $txt = ''
    if ($res.StdOut) { $txt = $res.StdOut.Trim() }
    if (-not $txt -and $res.StdErr) { $txt = $res.StdErr.Trim() }
    if (-not $txt) {
        if ($res.ExitCode -eq 0) { return 'ok' }
        return "exit code $($res.ExitCode)"
    }
    # strip ANSI escapes, then drop pipe/table-format noise lines, keeping the
    # first remaining non-empty line (Finding 4)
    $esc = [char]27
    $ansiPattern = [regex]::Escape($esc) + '\[[0-9;]*m'
    $clean = $txt -replace $ansiPattern, ''
    $lines = @($clean -split "`r?`n" | Where-Object {
        $_.Trim() -ne '' -and $_ -notmatch '^\s*(\||\+|At line|Line \|)'
    })
    if ($lines.Count -gt 0) { return $lines[0].Trim() }
    $txt
}

# ---------- in-process status readers ----------
# GET polls used to shell out to preheat.ps1 - a fresh pwsh per poll meant a
# JIT/CPU spike every minute (periodic fan roar, observed live). This
# read-only view is cheap to compute in-process; POST actions still shell out.

function Get-PreheatStatusObject {
    $tasks = @()
    try {
        foreach ($t in @(Get-PreheatJobs)) {
            $next = $null
            if ($t.next) { $next = $t.next.ToString('yyyy-MM-ddTHH:mm:ss') }
            $tasks += @{ name = $t.name; next = $next }
        }
    } catch { }
    @{ tasks = $tasks }
}

# ---------- HTTP plumbing ----------

function Read-RequestBody($request) {
    if (-not $request.HasEntityBody) { return '' }
    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
    try { $reader.ReadToEnd() } finally { $reader.Close() }
}

function Send-Bytes($context, [int]$statusCode, [byte[]]$bytes, [string]$contentType) {
    $context.Response.StatusCode = $statusCode
    $context.Response.ContentType = $contentType
    $context.Response.ContentLength64 = $bytes.Length
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.OutputStream.Close()
}

function Send-Json($context, [int]$statusCode, $obj) {
    # -InputObject (never pipe): a bare 0- or 1-element top-level array must
    # still serialize as a JSON array, not unwrap to a scalar
    $json = ConvertTo-Json -InputObject $obj -Compress -Depth 8
    Send-Bytes $context $statusCode ([System.Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8'
}

function Send-Html($context, [int]$statusCode, [string]$html) {
    # never let the browser heuristically cache the page - stale UI after a
    # redesign kept masquerading as a bug (observed live twice)
    $context.Response.Headers['Cache-Control'] = 'no-cache'
    Send-Bytes $context $statusCode ([System.Text.Encoding]::UTF8.GetBytes($html)) 'text/html; charset=utf-8'
}

# ---------- POST security gate (Finding 7) ----------

function Test-PostSecurity($context) {
    $req = $context.Request

    $ct = $req.ContentType
    if (-not $ct -or $ct -notlike '*application/json*') {
        Send-Json $context 400 @{ ok = $false; message = 'Content-Type must be application/json' }
        return $false
    }

    $origin  = $req.Headers['Origin']
    $referer = $req.Headers['Referer']
    foreach ($h in @($origin, $referer)) {
        if ($h) {
            # http://[::1]: is the same machine - a browser that resolved
            # localhost to IPv6 sends it, and rejecting it locked the user out
            if (-not ($h.StartsWith('http://localhost:') -or $h.StartsWith('http://127.0.0.1:') -or $h.StartsWith('http://[::1]:'))) {
                Send-Json $context 403 @{ ok = $false; message = 'origin not allowed' }
                return $false
            }
        }
    }

    $isLoopback = $false
    try {
        $remote = $req.RemoteEndPoint
        if ($remote -and $remote.Address) { $isLoopback = [System.Net.IPAddress]::IsLoopback($remote.Address) }
    } catch { }
    if (-not $isLoopback) {
        Send-Json $context 403 @{ ok = $false; message = 'forbidden' }
        return $false
    }

    $true
}

# ---------- API handlers ----------

function Handle-ApiStatus($context) {
    $preheatObj = $null
    $now = Get-Date
    $cacheAgeSec = [double]::PositiveInfinity
    if ($script:PreheatStatusCache.value) { $cacheAgeSec = ($now - $script:PreheatStatusCache.ts).TotalSeconds }
    if ($script:PreheatStatusCache.value -and $cacheAgeSec -lt $PreheatStatusCacheTtlSec) {
        # cache still fresh: serve it immediately, no task-scheduler query (Finding 3)
        $preheatObj = $script:PreheatStatusCache.value
    } else {
        try {
            $preheatObj = Get-PreheatStatusObject
            $script:PreheatStatusCache.value = $preheatObj
            $script:PreheatStatusCache.ts = $now
        } catch { }
        if (-not $preheatObj -and $script:PreheatStatusCache.value) {
            # query failed (or returned nothing): fall back to stale cache rather than blank
            $preheatObj = $script:PreheatStatusCache.value
        }
    }
    if (-not $preheatObj) { $preheatObj = @{ tasks = @() } }

    Send-Json $context 200 @{ preheat = $preheatObj }
}

function Handle-ApiRateLimits($context) {
    # cached usage windows, written by statusline-tap.cjs (empty {} until the
    # tap is installed and a statusline has rendered once)
    $obj = $null
    try {
        $p = Join-Path $Root 'state-ratelimits.json'
        if (Test-Path $p) { $obj = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json }
    } catch { }
    if (-not $obj) { $obj = @{} }
    Send-Json $context 200 $obj
}

function Handle-ApiLearn($context) {
    # 30-day rhythm + 7-day window-utilization report from preheat.ps1 learn
    $now = Get-Date
    $age = [double]::PositiveInfinity
    if ($script:LearnCache.value) { $age = ($now - $script:LearnCache.ts).TotalSeconds }
    if ($script:LearnCache.value -and $age -lt $LearnCacheTtlSec) {
        Send-Json $context 200 $script:LearnCache.value
        return
    }
    $obj = $null
    try {
        $st = Get-HistoryTimestamps 30
        if ($st.Count -eq 0) { $obj = @{ days = @(); waste = $null } }
        else { $obj = Get-LearnReport $st (Get-Date) }
    } catch { }
    if (-not $obj) { $obj = @{ days = @(); waste = $null } }
    $script:LearnCache.value = $obj
    $script:LearnCache.ts = $now
    Send-Json $context 200 $obj
}

function Handle-ApiEvents($context) {
    # the journal's fire records for the page's fire-history list (newest
    # first, capped; the page filters by age and count). [] until the first
    # fire has been logged. Get-FireEvents comes from the dot-sourced preheat.ps1.
    $ev = @()
    try { $ev = @(Get-FireEvents $LogPath 60) } catch { $ev = @() }
    Send-Json $context 200 @{ events = $ev }
}

function Get-ConfigMtime {
    # optimistic-lock token for schedule.json: a page that loaded rules hours
    # ago must not silently overwrite what the CLI wrote since. '' = no file.
    if (Test-Path $ConfigPath) {
        try { return [string](Get-Item $ConfigPath).LastWriteTimeUtc.Ticks } catch { }
    }
    ''
}

function Handle-ApiSchedule($context) {
    # rules + mtime only. proxy/_readme used to ride along and come straight
    # back on the next apply, so an old tab could resurrect a stale proxy.
    $rules = @()
    try {
        if (Test-Path $ConfigPath) {
            $raw = Get-Content $ConfigPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($raw) {
                $obj = $raw | ConvertFrom-Json
                if ($obj -and $obj.rules) { $rules = @($obj.rules) }
            }
        }
    } catch { }
    Send-Json $context 200 @{ rules = $rules; mtime = (Get-ConfigMtime) }
}

function Handle-PreheatOnce($context) {
    $data = $null
    try { $data = (Read-RequestBody $context.Request) | ConvertFrom-Json } catch { }
    if (-not $data -or -not $data.kind -or -not $data.value) {
        Send-Json $context 400 @{ ok = $false; message = 'expected {kind, value}' }; return
    }
    $kind  = [string]$data.kind
    $value = [string]$data.value
    # server-side validation: the client checks these too, but a non-browser
    # caller bypasses the client
    $cmdArgs = $null
    if ($kind -eq 'reset' -or $kind -eq 'at') {
        if ($value -notmatch '^\d{1,2}:\d{2}$') {
            Send-Json $context 400 @{ ok = $false; message = 'invalid time, expected HH:mm' }; return
        }
        # the shape check alone let 25:00 / 08:75 through to the backend, which
        # then threw deep inside Get-NextOccurrence with an unreadable message
        $colon = $value.IndexOf(':')
        if (([int]$value.Substring(0, $colon) -gt 23) -or ([int]$value.Substring($colon + 1) -gt 59)) {
            Send-Json $context 400 @{ ok = $false; message = 'invalid time, expected HH:mm (00:00-23:59)' }; return
        }
        $cmdArgs = @($kind, $value)
    } elseif ($kind -eq 'plus') {
        $v = $value
        if ($v -notmatch '^\+') { $v = '+' + $v }
        if ($v -notmatch '^\+\d{1,3}[hm]$') {
            Send-Json $context 400 @{ ok = $false; message = 'invalid offset, expected +Nh or +Nm' }; return
        }
        $cmdArgs = @($v)
    } else {
        Send-Json $context 400 @{ ok = $false; message = "unknown kind '$kind'" }; return
    }
    $res = Invoke-BackendCommand -ScriptPath $PreheatScript -CmdArgs $cmdArgs
    $script:PreheatStatusCache.ts = [datetime]::MinValue   # next poll shows the new task
    Send-Json $context 200 @{ ok = ($res.ExitCode -eq 0); message = (Get-ResultMessage $res) }
}

function Test-RuleSet($rules) {
    # -> $null when the set is writable, else the reason. The client validates
    # too, but a curl/extension caller bypasses the client and a bad reset time
    # only surfaces much later, as a task registered at the wrong hour.
    $known = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun')
    $list = @($rules)
    if ($list.Count -eq 0) { return 'rules must be a non-empty array' }
    foreach ($r in $list) {
        $days = @($r.days)
        if ($days.Count -eq 0) { return 'a rule has no days' }
        foreach ($d in $days) {
            if ($known -notcontains [string]$d) { return ("unknown day '{0}'" -f $d) }
        }
        $reset = [string]$r.reset
        if ($reset -notmatch '^\d{2}:\d{2}$') { return ("bad reset time '{0}', expected HH:mm" -f $reset) }
        if (([int]$reset.Substring(0, 2) -gt 23) -or ([int]$reset.Substring(3, 2) -gt 59)) {
            return ("reset time out of range '{0}', expected 00:00-23:59" -f $reset)
        }
    }
    $null
}

function Handle-PreheatApply($context) {
    $data = $null
    try { $data = (Read-RequestBody $context.Request) | ConvertFrom-Json } catch { }
    # presence, not truthiness: an empty array must reach Test-RuleSet so the
    # caller hears "non-empty array", not "expected {rules}"
    if (-not $data -or -not $data.PSObject.Properties['rules']) {
        Send-Json $context 400 @{ ok = $false; message = 'expected {rules:[...]}' }; return
    }
    $why = Test-RuleSet $data.rules
    if ($why) { Send-Json $context 400 @{ ok = $false; message = ('invalid rules: ' + $why) }; return }

    # optimistic lock: a tab left open across a CLI `preheat learn auto` would
    # otherwise apply its hours-old grid over the newer file without a word
    $hasBase = $false
    try { if ($data.PSObject.Properties['baseMtime']) { $hasBase = $true } } catch { }
    if ($hasBase -and ((Get-ConfigMtime) -ne [string]$data.baseMtime)) {
        Send-Json $context 409 @{
            ok = $false; code = 'stale'
            message = 'schedule.json changed since this page loaded - the editor was reloaded from disk, check it and apply again'
        }
        return
    }

    $existing = $null
    try { if (Test-Path $ConfigPath) { $existing = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } } catch { }
    $proxy = ''
    if ($existing -and $existing.PSObject.Properties['proxy']) { $proxy = $existing.proxy }
    # always write the canonical hint: preserving the old value once kept a
    # stale command name alive in personal configs long after a rename
    $readme = 'days: Mon..Sun | reset = HH:mm target reset time (previous 5h window expiry); fire time auto = reset - 5h | edit then run: preheat apply'

    $rulesOut = @()
    foreach ($r in @($data.rules)) {
        # dedupe days: a grid that sent Mon twice would register the same
        # weekday trigger twice
        $days = @()
        foreach ($d in @($r.days)) {
            $ds = [string]$d
            if ($days -notcontains $ds) { $days += $ds }
        }
        $rulesOut += [ordered]@{ days = $days; reset = [string]$r.reset }
    }
    $newConfig = [ordered]@{ _readme = $readme; proxy = $proxy; rules = $rulesOut }

    try {
        $null = Backup-File $ConfigPath
        Write-Utf8NoBom $ConfigPath (ConvertTo-Json -InputObject $newConfig -Depth 6)
    } catch {
        Send-Json $context 500 @{ ok = $false; message = "failed to write schedule.json: $($_.Exception.Message)" }
        return
    }

    $res = Invoke-BackendCommand -ScriptPath $PreheatScript -CmdArgs @('apply')
    $script:PreheatStatusCache.ts = [datetime]::MinValue   # next poll shows the new tasks
    Send-Json $context 200 @{ ok = ($res.ExitCode -eq 0); message = (Get-ResultMessage $res); mtime = (Get-ConfigMtime) }
}

# ---------- request dispatch ----------

function Handle-Request($context) {
    $req    = $context.Request
    $path   = $req.Url.AbsolutePath
    $method = $req.HttpMethod
    Write-PanelLog ('{0} {1}' -f $method, $path)

    if ($method -eq 'GET' -and $path -eq '/') {
        if (Test-Path $IndexPath) {
            Send-Html $context 200 (Get-Content $IndexPath -Raw -Encoding UTF8)
        } else {
            Send-Html $context 404 '<h1>web/index.html not found</h1>'
        }
        return
    }
    if ($method -eq 'GET' -and $path -eq '/api/status')   { Handle-ApiStatus $context; return }
    if ($method -eq 'GET' -and $path -eq '/api/schedule') { Handle-ApiSchedule $context; return }
    if ($method -eq 'GET' -and $path -eq '/api/ratelimits') { Handle-ApiRateLimits $context; return }
    if ($method -eq 'GET' -and $path -eq '/api/learn')      { Handle-ApiLearn $context; return }
    if ($method -eq 'GET' -and $path -eq '/api/events')     { Handle-ApiEvents $context; return }

    if ($method -eq 'POST' -and -not (Test-PostSecurity $context)) { return }

    if ($method -eq 'POST' -and $path -eq '/api/preheat/once')    { Handle-PreheatOnce $context; return }
    if ($method -eq 'POST' -and $path -eq '/api/preheat/apply')   { Handle-PreheatApply $context; return }

    Send-Json $context 404 @{ ok = $false; message = "not found: $method $path" }
}

# ---------- main ----------

$Prefix = "http://localhost:$Port/"
# singleton guard: a second instance must fail loudly, never zombie (observed live)
# Get-NetTCPConnection is Windows-only; macOS asks lsof the same question
$portBusy = $false
if ($OnMac) {
    # no lsof -> treat the port as free; a real clash still fails loudly at the bind below
    try {
        & lsof -nP -iTCP:$Port -sTCP:LISTEN 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $portBusy = $true }
    } catch { }
} elseif (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
    $portBusy = $true
}
if ($portBusy) {
    # "listening" is not "it is us": some other server on 7878 used to send the
    # user to a URL that answers with somebody else's app. Ask the API first.
    # default to "it is us": a panel in the middle of an apply answers nothing
    # for up to 120s, and sending the user off to a second instance on another
    # port would have two panels writing schedule.json
    $isPanel = $true
    try {
        $probe = Invoke-WebRequest -Uri ($Prefix + 'api/status') -UseBasicParsing -TimeoutSec 3
        if ($probe.Content -notlike '*"preheat"*') { $isPanel = $false }
    } catch {
        # an HTTP error status is a real answer from something that is not the
        # panel (/api/status here is always 200); a timeout is not an answer
        if ($_.Exception.Response) { $isPanel = $false }
    }
    if ($isPanel) {
        Write-Host ('port {0} already listening - panel is probably running; open {1}' -f $Port, $Prefix)
    } else {
        Write-Host ('port {0} is in use by another program (not this panel) - start with -Port <another port>' -f $Port)
    }
    exit 2
}
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($Prefix)
$bound = $false
for ($bindTry = 1; $bindTry -le 3 -and -not $bound; $bindTry++) {
    try {
        $listener.Start()
        $bound = $true
    } catch {
        if ($bindTry -ge 3) {
            Write-Host ('failed to start listener on {0}: {1}' -f $Prefix, $_.Exception.Message)
            Write-PanelLog ('FATAL: bind failed - ' + $_.Exception.Message)
            exit 1
        }
        # the port can linger briefly after a killed instance (observed live) - wait and retry
        Start-Sleep -Seconds 3
    }
}

Write-Host ''
Write-Host ('claude-preheat panel running at {0}' -f $Prefix)
Write-Host 'press Ctrl+C to stop'
Write-Host ''
Write-PanelLog ('start ' + $Prefix)

if (-not $NoBrowser) {
    # Start-Process on a bare URL only works on Windows; macOS uses open(1)
    try { if ($OnMac) { & open $Prefix } else { Start-Process $Prefix } } catch { }
}

try {
    while ($listener.IsListening) {
        $contextTask = $listener.GetContextAsync()
        # poll instead of a blocking GetContext() so Ctrl+C actually has a chance to land
        while (-not $contextTask.AsyncWaitHandle.WaitOne(500)) { }
        $context = $null
        try {
            $context = $contextTask.GetAwaiter().GetResult()
        } catch {
            if (-not $listener.IsListening) {
                # listener died: exit visibly instead of looping on a corpse
                Write-PanelLog ('FATAL: listener died - ' + $_.Exception.Message)
                break
            }
            Write-PanelLog ('WARN: accept failed - ' + $_.Exception.Message)
            continue
        }
        try {
            Handle-Request $context
        } catch {
            Write-PanelLog ('ERROR: ' + $_.Exception.Message)
            try {
                $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"message":"internal error"}')
                $context.Response.StatusCode = 500
                $context.Response.ContentType = 'application/json; charset=utf-8'
                $context.Response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                $context.Response.OutputStream.Close()
            } catch { }
        }
    }
} finally {
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
    Write-PanelLog 'stop'
    Write-Host ''
    Write-Host 'panel stopped'
}
