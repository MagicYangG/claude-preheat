#Requires -Version 5.1
<#
claude-preheat panel -- local web control panel

Pure PowerShell HttpListener server that serves web/index.html and implements
the JSON API the page talks to. It owns no state of its own: every read/write
goes through preheat.ps1 (single source of truth) so the CLI and the web
panel can never disagree.

Usage: panel.ps1 [-Port 7878] [-NoBrowser]

Endpoints (see web/index.html for the client side). provider (query string on
GETs, body field on POSTs) is claude|codex; missing = claude, so an old page
keeps working.
  GET  /                     web/index.html
  GET  /api/status           {preheat:{tasks:[{name,next,provider}]}, codex:{installed,exeKind}}
  GET  /api/schedule         ?provider -> {rules:[...], mtime:"<token>"} - rules
                             only, so a stale tab can never write back a
                             proxy/_readme it read hours ago; mtime is the
                             optimistic-lock token of THAT section only
  GET  /api/ratelimits       ?provider - claude: cache written by statusline-tap.cjs
                             and fire; codex: state-ratelimits-codex.json verbatim
  GET  /api/learn            30-day rhythm + 7-day window-utilization report
                             (codex: {unsupported:true})
  GET  /api/events           ?provider -> {events:[...]} fire history, newest first
  POST /api/preheat/once     {provider?, kind:"reset"|"at"|"plus", value:"HH:mm"|"2h"}
  POST /api/preheat/apply    {provider?, rules:[{days:[...], reset:"HH:mm"}, ...], baseMtime?}
                             409 {code:"stale"} when that section moved under the tab
  POST /api/codex/refresh    one `preheat status -Codex -Json` (the Refresh button;
                             the panel never starts codex on its own)

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
# PREHEAT_PANEL_LOG: the self-test points this at its temp dir, so a test run
# never appends to the real panel log inside the repo
$PanelLog     = if ($env:PREHEAT_PANEL_LOG) { $env:PREHEAT_PANEL_LOG } else { Join-Path $Root 'panel-log.txt' }
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
# constraint and throw. Drop them (and its $Command/$Arg/$Job) right away.
Remove-Variable -Name Json, Command, Arg, Job, Provider, Codex -Scope Script -ErrorAction SilentlyContinue

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

# Quote-Arg (argv quoting hardened against \" splicing) lives in platform.ps1

function Get-DescendantPids([int]$Id) {
    # macOS/Linux: every descendant of $Id, deepest first (pgrep -P walks one
    # level; an npm codex is node -> codex -> sandbox, two levels below us)
    foreach ($c in @(& pgrep -P $Id 2>$null)) {
        if ("$c" -match '^\d+$') { Get-DescendantPids ([int]"$c"); [int]"$c" }
    }
}

function Stop-BackendTree($p) {
    # never throws. Killing only the shell orphaned its claude/codex children,
    # which kept running (and holding locks) after a timeout - an exec ping
    # whose stdin is a file never notices. Windows: taskkill /T walks the
    # tree; macOS has no 5.1-safe tree kill, so the descendants deepest
    # first, then the shell.
    try {
        if ($OnMac -or $OnLinux) {
            foreach ($d in @(Get-DescendantPids $p.Id)) { Stop-Process -Id $d -Force -ErrorAction SilentlyContinue }
        } else {
            & taskkill.exe /T /F /PID $p.Id 2>$null | Out-Null
        }
    } catch { }
    try { if (-not $p.HasExited) { $p.Kill() } } catch { }
}

function Invoke-BackendCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$CmdArgs = @(),
        [int]$TimeoutSec = 120
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
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            Stop-BackendTree $p
            return @{ ExitCode = -1; StdOut = ''; StdErr = ('timeout after {0}s' -f $TimeoutSec) }
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
            $tasks += @{ name = $t.name; next = $next; provider = (Get-JobProvider $t.name) }
        }
    } catch { }
    @{ tasks = $tasks }
}

function Get-CodexStatusObject {
    # candidate paths on disk only, never a codex process: this rides the
    # status poll and the listener is single-threaded
    $exe = $null
    try { $exe = Resolve-CodexExe } catch { }
    if ($exe) { return @{ installed = $true; exeKind = [string]$exe.kind } }
    @{ installed = $false; exeKind = $null }
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
    $codexObj = $null
    $now = Get-Date
    $cacheAgeSec = [double]::PositiveInfinity
    if ($script:PreheatStatusCache.value) { $cacheAgeSec = ($now - $script:PreheatStatusCache.ts).TotalSeconds }
    if ($script:PreheatStatusCache.value -and $cacheAgeSec -lt $PreheatStatusCacheTtlSec) {
        # cache still fresh: serve it immediately, no task-scheduler query (Finding 3)
        $preheatObj = $script:PreheatStatusCache.value
        $codexObj = $script:PreheatStatusCache.codex
    } else {
        try {
            $preheatObj = Get-PreheatStatusObject
            $codexObj = Get-CodexStatusObject
            $script:PreheatStatusCache.value = $preheatObj
            $script:PreheatStatusCache.codex = $codexObj
            $script:PreheatStatusCache.ts = $now
        } catch { }
        if (-not $preheatObj -and $script:PreheatStatusCache.value) {
            # query failed (or returned nothing): fall back to stale cache rather than blank
            $preheatObj = $script:PreheatStatusCache.value
            $codexObj = $script:PreheatStatusCache.codex
        }
    }
    if (-not $preheatObj) { $preheatObj = @{ tasks = @() } }
    if (-not $codexObj) { $codexObj = @{ installed = $false; exeKind = $null } }

    Send-Json $context 200 @{ preheat = $preheatObj; codex = $codexObj }
}

function Get-RequestProvider($context) {
    # ?provider= on a GET: 'claude' when absent (old pages), $null when it is
    # anything but the two known names - the caller answers 400
    $p = $null
    try { $p = $context.Request.QueryString['provider'] } catch { }
    if (-not $p) { return 'claude' }
    $p = ([string]$p).ToLowerInvariant()
    if ($p -eq 'claude' -or $p -eq 'codex') { return $p }
    $null
}

function Get-BodyProvider($data) {
    # the same rule for a POST body field
    if (-not $data -or -not $data.PSObject.Properties['provider'] -or -not $data.provider) { return 'claude' }
    $p = ([string]$data.provider).ToLowerInvariant()
    if ($p -eq 'claude' -or $p -eq 'codex') { return $p }
    $null
}

function Send-BadProvider($context) {
    Send-Json $context 400 @{ ok = $false; message = 'provider must be claude or codex' }
}

function Handle-ApiRateLimits($context) {
    $prov = Get-RequestProvider $context
    if (-not $prov) { Send-BadProvider $context; return }
    if ($prov -eq 'codex') {
        # written by codex fire / status -Codex / Refresh. Sent verbatim: a
        # re-serialized copy turns its ISO stamps into engine-specific date
        # shapes. Parsed only so a half-written file reads as {}.
        $raw = $null
        try {
            $cp = Join-Path $Root 'state-ratelimits-codex.json'
            if (Test-Path $cp) {
                $raw = Get-Content $cp -Raw -Encoding UTF8
                if (-not ($raw | ConvertFrom-Json)) { $raw = $null }
            }
        } catch { $raw = $null }
        if (-not $raw) { $raw = '{}' }
        Send-Bytes $context 200 ([System.Text.Encoding]::UTF8.GetBytes($raw)) 'application/json; charset=utf-8'
        return
    }
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
    $prov = Get-RequestProvider $context
    if (-not $prov) { Send-BadProvider $context; return }
    # learn reads Claude's prompt history only (Codex learn is planned for beta.2)
    if ($prov -eq 'codex') { Send-Json $context 200 @{ unsupported = $true }; return }
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
    # fire has been logged. Get-FireEvents comes from the dot-sourced preheat.ps1;
    # it filters by provider before pairing chase records with their fire.
    $prov = Get-RequestProvider $context
    if (-not $prov) { Send-BadProvider $context; return }
    $ev = @()
    try { $ev = @(Get-FireEvents $LogPath 60 -Provider $prov) } catch { $ev = @() }
    Send-Json $context 200 @{ events = $ev }
}

function Read-PanelConfig {
    # -> @{ raw; obj } of schedule.json as it is on disk right now (raw $null =
    # no file; obj $null = no file or it does not parse)
    $raw = $null; $obj = $null
    if (Test-Path $ConfigPath) {
        try { $raw = Get-Content $ConfigPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
        if ($raw) { try { $obj = $raw | ConvertFrom-Json } catch { $obj = $null } }
    }
    @{ raw = $raw; obj = $obj }
}

function Get-SectionRules($obj, [string]$Provider) {
    # claude = top-level rules, codex = codex.rules; $null when absent
    if (-not $obj) { return $null }
    if ($Provider -eq 'codex') {
        if ($obj.PSObject.Properties['codex'] -and $obj.codex -and $obj.codex.PSObject.Properties['rules']) { return ,$obj.codex.rules }
        return $null
    }
    if ($obj.PSObject.Properties['rules']) { return ,$obj.rules }
    $null
}

function Get-ConfigMtime([string]$Provider = 'claude') {
    # optimistic-lock token, one per section: a page that loaded rules hours
    # ago must not silently overwrite what the CLI wrote since - but a save on
    # the Codex tab must not 409 the Claude tab, which one file mtime did.
    # Hash of that section's rules as read (the writer keeps every other key
    # from disk anyway). '' = no file; an unparseable file hashes its raw text.
    $c = Read-PanelConfig
    if (-not $c.raw) { return '' }
    $text = $c.raw
    if ($c.obj) { $text = ConvertTo-Json -InputObject (Get-SectionRules $c.obj $Provider) -Compress -Depth 8 }
    # 5.1 serializes an absent section to nothing at all, 7 to 'null'
    if (-not $text) { $text = 'null' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$text)) } finally { $sha.Dispose() }
    -join @($h[0..7] | ForEach-Object { $_.ToString('x2') })
}

function Handle-ApiSchedule($context) {
    # rules + mtime only. proxy/_readme used to ride along and come straight
    # back on the next apply, so an old tab could resurrect a stale proxy.
    $prov = Get-RequestProvider $context
    if (-not $prov) { Send-BadProvider $context; return }
    $rules = @()
    try {
        $r = Get-SectionRules (Read-PanelConfig).obj $prov
        if ($r) { $rules = @($r) }
    } catch { }
    Send-Json $context 200 @{ rules = $rules; mtime = (Get-ConfigMtime $prov) }
}

function Handle-PreheatOnce($context) {
    $data = $null
    try { $data = (Read-RequestBody $context.Request) | ConvertFrom-Json } catch { }
    if (-not $data -or -not $data.kind -or -not $data.value) {
        Send-Json $context 400 @{ ok = $false; message = 'expected {kind, value}' }; return
    }
    $prov = Get-BodyProvider $data
    if (-not $prov) { Send-BadProvider $context; return }
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
    if ($prov -eq 'codex') { $cmdArgs += '-Codex' }
    $res = Invoke-BackendCommand -ScriptPath $PreheatScript -CmdArgs $cmdArgs
    $script:PreheatStatusCache.ts = [datetime]::MinValue   # next poll shows the new task
    Send-Json $context 200 @{ ok = ($res.ExitCode -eq 0); message = (Get-ResultMessage $res) }
}

function Test-RuleSet($rules, [switch]$AllowEmpty) {
    # -> $null when the set is writable, else the reason. The client validates
    # too, but a curl/extension caller bypasses the client and a bad reset time
    # only surfaces much later, as a task registered at the wrong hour.
    # -AllowEmpty (Codex): an empty section just means no weekly Codex
    # preheats. Clearing Claude stays `preheat off`, as before.
    $known = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun')
    $list = @($rules)
    if ($list.Count -eq 0) {
        if ($AllowEmpty) { return $null }
        return 'rules must be a non-empty array'
    }
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
    $prov = Get-BodyProvider $data
    if (-not $prov) { Send-BadProvider $context; return }
    $why = Test-RuleSet $data.rules -AllowEmpty:($prov -eq 'codex')
    if ($why) { Send-Json $context 400 @{ ok = $false; message = ('invalid rules: ' + $why) }; return }

    # optimistic lock: a tab left open across a CLI `preheat learn auto` would
    # otherwise apply its hours-old grid over the newer file without a word.
    # Before anything is written or spawned.
    # a Codex save rewrites the whole file: on one that does not parse it
    # would keep nothing of the Claude rules or any other key. Refuse rather
    # than guess (a Claude save keeps its old behaviour).
    if ($prov -eq 'codex') {
        $pc = Read-PanelConfig
        if ($pc.raw -and (-not $pc.obj)) {
            Send-Json $context 409 @{ ok = $false; code = 'unparseable'; message = 'schedule.json does not parse - fix it (or restore schedule.json.bak), then apply again' }
            return
        }
        # its apply would wait minutes on the fire's lock, far past the backend timeout
        if (Test-CodexFireRunning) {
            Send-Json $context 409 @{ ok = $false; code = 'busy'; message = 'a Codex fire is running right now - try again in a few minutes' }
            return
        }
    }
    $hasBase = $false
    try { if ($data.PSObject.Properties['baseMtime']) { $hasBase = $true } } catch { }
    if ($hasBase -and ((Get-ConfigMtime $prov) -ne [string]$data.baseMtime)) {
        Send-Json $context 409 @{
            ok = $false; code = 'stale'
            message = 'schedule.json changed since this page loaded - the editor was reloaded from disk, check it and apply again'
        }
        return
    }

    $existing = (Read-PanelConfig).obj
    $proxy = ''
    if ($existing -and $existing.PSObject.Properties['proxy']) { $proxy = $existing.proxy }
    # the chase (follow-up preheat) opt-out lives in the same file: keep it
    $chase = $null
    if ($existing -and $existing.PSObject.Properties['chase']) { $chase = $existing.chase }
    # always write the canonical hint: preserving the old value once kept a
    # stale command name alive in personal configs long after a rename
    $readme = 'days: Mon..Sun | reset = HH:mm target reset time (previous 5h window expiry); fire time auto = reset - 5h | edit then run: preheat apply | chase: false = no follow-up ping when a scheduled preheat lands in a running window'

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
    # only this tab's section is replaced. A Codex save keeps the Claude rules
    # on disk (top-level rules may be [] for Codex-only users).
    $claudeRules = $rulesOut
    if ($prov -eq 'codex') {
        $claudeRules = @()
        $er = Get-SectionRules $existing 'claude'
        if ($er) { $claudeRules = @($er) }
    }
    $newConfig = [ordered]@{ _readme = $readme; proxy = $proxy }
    # top-level rules from a Codex save only when the file had them: a new
    # [] would change the Claude tab's token and 409 its next save
    if (($prov -eq 'claude') -or (-not $existing) -or $existing.PSObject.Properties['rules']) { $newConfig.rules = $claudeRules }
    if ($null -ne $chase) { $newConfig.chase = [bool]$chase }
    # every other key rides along untouched (codex, whatever a later version
    # adds) - this writer used to drop what it did not know. Appended after the
    # fixed four, so a file without extra keys is written exactly as before.
    if ($existing) {
        foreach ($pp in $existing.PSObject.Properties) {
            if (@('_readme', 'proxy', 'rules', 'chase') -notcontains $pp.Name) { $newConfig[$pp.Name] = $pp.Value }
        }
    }
    if ($prov -eq 'codex') {
        # codex.rules replaced; chase, home and anything else in it kept
        $cx = [ordered]@{}
        $hadRules = $false
        if ($newConfig.Contains('codex') -and $newConfig['codex']) {
            foreach ($pp in $newConfig['codex'].PSObject.Properties) {
                if ($pp.Name -eq 'rules') { $cx['rules'] = $rulesOut; $hadRules = $true }
                else { $cx[$pp.Name] = $pp.Value }
            }
        }
        if (-not $hadRules) { $cx['rules'] = $rulesOut }
        $newConfig['codex'] = $cx
    }

    try {
        $null = Backup-File $ConfigPath
        # deep enough for whatever the kept keys nest: past -Depth a value
        # turns into the literal text of its type name
        Write-Utf8NoBom $ConfigPath (ConvertTo-Json -InputObject $newConfig -Depth 20)
    } catch {
        Send-Json $context 500 @{ ok = $false; message = "failed to write schedule.json: $($_.Exception.Message)" }
        return
    }

    # this side only: a Claude save must not re-register the Codex tasks (or
    # vice versa), and one side failing must not read as the other failing
    $res = Invoke-BackendCommand -ScriptPath $PreheatScript -CmdArgs @('apply', '-Provider', $prov)
    $script:PreheatStatusCache.ts = [datetime]::MinValue   # next poll shows the new tasks
    Send-Json $context 200 @{ ok = ($res.ExitCode -eq 0); message = (Get-ResultMessage $res); mtime = (Get-ConfigMtime $prov) }
}

function Test-CodexFireRunning {
    # the fire path's own freshness rule for its lock: present, written in the
    # last 20 min, and its pid still alive
    $lk = Join-Path $Root '.fire-codex.lock'
    if (-not (Test-Path $lk)) { return $false }
    try {
        # -Force: a dot file is hidden from a plain Get-Item on macOS
        if ((Get-Item -Force $lk).LastWriteTime -lt (Get-Date).AddMinutes(-20)) { return $false }
        $l = Get-Content $lk -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
        if ($l -and $l.pid -and (Get-Process -Id ([int]$l.pid) -ErrorAction SilentlyContinue)) { return $true }
    } catch { }
    $false
}

function Handle-CodexRefresh($context) {
    # the Refresh button: one live quota read through the CLI. The listener is
    # single-threaded, so two clicks never run two codex processes at once; a
    # scheduled Codex fire in flight owns the account, so refuse while it runs.
    if (Test-CodexFireRunning) {
        Send-Json $context 409 @{ ok = $false; code = 'busy'; message = 'a Codex fire is running right now - try again in a few minutes' }
        return
    }
    $res = Invoke-BackendCommand -ScriptPath $PreheatScript -CmdArgs @('status', '-Codex', '-Json') -TimeoutSec 60
    # status -Codex -Json may exit non-zero (signed out) and still print its
    # object; fall back to the last line that parses as one
    $obj = $null
    if ($res.StdOut) {
        try { $obj = $res.StdOut | ConvertFrom-Json } catch { $obj = $null }
        if (-not $obj) {
            $lines = @($res.StdOut -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') })
            for ($i = $lines.Count - 1; $i -ge 0 -and -not $obj; $i--) {
                try { $obj = $lines[$i] | ConvertFrom-Json } catch { }
            }
        }
    }
    if (-not $obj) { Send-Json $context 200 @{ ok = $false; message = (Get-ResultMessage $res) }; return }
    Send-Json $context 200 $obj
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
    if ($method -eq 'POST' -and $path -eq '/api/codex/refresh')   { Handle-CodexRefresh $context; return }

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
