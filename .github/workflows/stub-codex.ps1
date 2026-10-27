# Stub codex for the self-test (test.ps1) and the macOS e2e. NOT shipped
# behaviour: it plays both halves of the real binary that preheat touches -
# `app-server --stdio` (newline JSON-RPC) and `exec ... --json` (JSONL) - and
# never talks to the network. Pure ASCII; must run on Windows PowerShell 5.1
# and pwsh 7 (the 5.1 CI job hosts it with 5.1).
#
# Driven by a JSON config FILE, not by env vars: a launchd child sees only the
# plist's environment, so the e2e fire could never inherit a STUB_* variable.
#   path: $env:STUB_CODEX_CONFIG, else stub-config.json next to this script
#   { profile: plus5h|free30d|go30d|pro|swapped|nearby|signedout|apikey,
#     r5: epoch|null    (null = idle: the 5h reset slides with the clock),
#     anchor: bool      (a good exec freezes the 5h reset at now + 18000),
#     exec: ok|limit|auth|hang|usage, rpc: ok|hang|crash,
#     used5: number     (5h used percent, default 12),
#     callsLog: path    (every start, env, RPC method and exec argv),
#     state: path       (the frozen reset an anchoring exec leaves behind) }
$ErrorActionPreference = 'Stop'
$cfgPath = $env:STUB_CODEX_CONFIG
if (-not $cfgPath) { $cfgPath = Join-Path $PSScriptRoot 'stub-config.json' }
$cfg = $null
try { $cfg = [System.IO.File]::ReadAllText($cfgPath) | ConvertFrom-Json } catch { }

function Get-StubValue([string]$Name, $Default) {
    if ($cfg -and $cfg.PSObject.Properties[$Name] -and ($null -ne $cfg.$Name)) { return $cfg.$Name }
    $Default
}

$callsLog = [string](Get-StubValue 'callsLog' '')
function Write-StubCall([string]$Line) {
    if (-not $callsLog) { return }
    # several stub processes can append in the same second: retry a locked file
    for ($i = 0; $i -lt 20; $i++) {
        try { [System.IO.File]::AppendAllText($callsLog, $Line + "`n"); return } catch { Start-Sleep -Milliseconds 50 }
    }
}

$argv = @($args | ForEach-Object { [string]$_ })
Write-StubCall ('start pid=' + $PID + ' argv=' + ($argv -join ' '))
Write-StubCall ('env https=' + $env:HTTPS_PROXY + ' http=' + $env:HTTP_PROXY + ' home=' + $env:CODEX_HOME + ' rustlog=' + $env:RUST_LOG)

if ($argv -contains '--version') { [Console]::Out.WriteLine('codex-cli 0.99.0-stub'); exit 0 }
if (($argv.Count -eq 0) -or ($argv -contains '--help')) { [Console]::Out.WriteLine('Usage: codex [OPTIONS] [PROMPT]'); exit 0 }

# split the -c key=value pairs (global or per-subcommand) from the rest
$pairs = @(); $rest = @()
for ($i = 0; $i -lt $argv.Count; $i++) {
    if (($argv[$i] -ceq '-c') -and ($i + 1 -lt $argv.Count)) { $pairs += $argv[$i + 1]; $i++ }
    else { $rest += $argv[$i] }
}

function Exit-Usage([string]$Why) {
    [Console]::Error.WriteLine("error: unexpected argument '" + $Why + "' found")
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine('Usage: codex exec [OPTIONS] [PROMPT]')
    Write-StubCall ('refused ' + $Why)
    exit 2
}

$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$statePath = [string](Get-StubValue 'state' '')
function Get-AnchoredReset {
    if ($statePath -and (Test-Path $statePath)) {
        try { return [long](([System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json).r5) } catch { }
    }
    $null
}

# ---------------------------------------------------------------- app-server
if ($rest.Count -ge 1 -and $rest[0] -eq 'app-server') {
    # only the private stdio child: `app-server daemon` / `proxy` would attach
    # to the instance the desktop app shares
    if (($rest.Count -ne 2) -or ($rest[1] -ne '--stdio')) { Exit-Usage ($rest -join ' ') }
    $stubProfile = [string](Get-StubValue 'profile' 'plus5h')
    $rpcMode = [string](Get-StubValue 'rpc' 'ok')
    $plan = 'plus'
    if ($stubProfile -eq 'free30d') { $plan = 'free' }
    if ($stubProfile -eq 'go30d') { $plan = 'go' }
    if ($stubProfile -eq 'pro') { $plan = 'pro' }

    function Write-Reply($Obj) {
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject $Obj -Depth 10 -Compress))
        [Console]::Out.Flush()
    }
    function New-Window($Used, $Mins, $Reset) { [ordered]@{ usedPercent = $Used; windowDurationMins = $Mins; resetsAt = $Reset } }
    function Get-RateLimits {
        $t = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $r5 = Get-AnchoredReset
        if ($null -eq $r5) {
            $c = Get-StubValue 'r5' $null
            # an idle window reports "now + 5h" and slides with every read
            if ($null -ne $c) { $r5 = [long]$c } else { $r5 = $t + 18000 }
        }
        $w5 = New-Window (Get-StubValue 'used5' 12) 300 $r5
        $wk = New-Window 40 10080 ([long]([math]::Floor($t / 3600) * 3600 + 259200))
        $snap = [ordered]@{ limitId = 'codex'; limitName = $null; planType = $plan }
        switch ($stubProfile) {
            'nearby'  { $snap.primary = New-Window (Get-StubValue 'used5' 12) 302 $r5; $snap.secondary = $wk }
            'swapped' { $snap.primary = $wk; $snap.secondary = $w5 }
            'free30d' { $snap.primary = New-Window 5 43200 ($t + 20 * 86400) }
            'go30d'   { $snap.primary = New-Window 5 43200 ($t + 20 * 86400) }
            'pro'     { }
            default   { $snap.primary = $w5; $snap.secondary = $wk }
        }
        [ordered]@{ rateLimits = $snap; rateLimitsByLimitId = [ordered]@{ codex = $snap }; accountId = 'acct-stub-0001' }
    }

    while ($true) {
        $line = [Console]::In.ReadLine()
        if ($null -eq $line) { break }
        if (-not $line.Trim()) { continue }
        $msg = $null
        try { $msg = $line | ConvertFrom-Json } catch { continue }
        $method = [string]$msg.method
        $params = ''
        if ($msg.PSObject.Properties['params'] -and ($null -ne $msg.params)) { $params = ConvertTo-Json -InputObject $msg.params -Depth 6 -Compress }
        Write-StubCall ('rpc ' + $method + ' ' + $params)
        if (-not $msg.PSObject.Properties['id'] -or ($null -eq $msg.id)) { continue }   # a notification
        $id = $msg.id
        switch ($method) {
            'initialize' {
                Write-Reply ([ordered]@{ id = $id; result = [ordered]@{ userAgent = 'stub/0.99.0' } })
                if ($rpcMode -eq 'crash') { [Console]::Error.WriteLine('stub codex: crashed after initialize'); exit 3 }
            }
            'account/read' {
                $acct = [ordered]@{ type = 'chatgpt'; email = 'stub.user@example.com'; planType = $plan; accountId = 'acct-stub-0001' }
                if ($stubProfile -eq 'signedout') { $acct = $null }
                if ($stubProfile -eq 'apikey') { $acct = [ordered]@{ type = 'apiKey' } }
                Write-Reply ([ordered]@{ id = $id; result = [ordered]@{ account = $acct; requiresOpenaiAuth = $true } })
            }
            'account/rateLimits/read' {
                if ($rpcMode -eq 'hang') { Start-Sleep -Seconds 600; exit 0 }
                if ($stubProfile -eq 'signedout') {
                    Write-Reply ([ordered]@{ id = $id; error = [ordered]@{ code = -32600; message = 'not logged in: run codex login' } })
                } elseif ($stubProfile -eq 'apikey') {
                    Write-Reply ([ordered]@{ id = $id; error = [ordered]@{ code = -32600; message = 'chatgpt authentication required to read rate limits' } })
                } else {
                    Write-Reply ([ordered]@{ id = $id; result = (Get-RateLimits) })
                }
            }
            default {
                # still logged above, so a test sees any method that reached the wire
                Write-Reply ([ordered]@{ id = $id; error = [ordered]@{ code = -32601; message = ('method not found: ' + $method) } })
            }
        }
    }
    exit 0
}

# ---------------------------------------------------------------------- exec
if ($rest.Count -ge 1 -and $rest[0] -eq 'exec') {
    # stdin first, like the real exec: a parent that leaves it open hangs here
    # until its own timeout (openai/codex#20919) - the test sees that as a fail
    $stdinText = [Console]::In.ReadToEnd()
    Write-StubCall ('exec stdin=' + $stdinText.Length + ' argv=' + ($argv -join ' '))
    # the exact argv of Invoke-CodexPing, token by token and case-sensitive: an
    # added -m, --profile, --oss, a second -s, anything, is refused - not a
    # list of known-bad flags. <dir> = any non-empty -C value.
    $expect = @('exec', '--ephemeral', '--skip-git-repo-check', '--ignore-user-config', '--ignore-rules',
                '-s', 'read-only', '-C', '<dir>', '--color', 'never', '--json', 'Reply with exactly: hi')
    if ($rest.Count -ne $expect.Count) { Exit-Usage ('argv ' + ($rest -join ' ')) }
    for ($i = 0; $i -lt $expect.Count; $i++) {
        if ($expect[$i] -ceq '<dir>') { if (-not $rest[$i]) { Exit-Usage '-C <dir>' }; continue }
        if ($rest[$i] -cne $expect[$i]) { Exit-Usage $rest[$i] }
    }
    # -c: every feature switch off, plus only the four login keys passed through
    $feat = @('features.hooks=false', 'features.memories=false', 'features.goals=false', 'features.apps=false', 'features.plugins=false')
    foreach ($p in $feat) { if ($pairs -cnotcontains $p) { Exit-Usage ('-c ' + $p) } }
    foreach ($p in $pairs) {
        if (($feat -cnotcontains $p) -and ($p -cnotmatch '^(cli_auth_credentials_store|forced_login_method|forced_chatgpt_workspace_id|chatgpt_base_url)=')) { Exit-Usage ('-c ' + $p) }
    }

    $mode = [string](Get-StubValue 'exec' 'ok')
    switch ($mode) {
        'usage' { Exit-Usage '--ignore-rules' }
        'hang'  { Start-Sleep -Seconds 600; exit 0 }
        'auth'  {
            [Console]::Out.WriteLine('{"type":"error","message":"Not logged in. Run codex login."}')
            [Console]::Error.WriteLine('Error: Not logged in')
            exit 1
        }
        'limit' {
            [Console]::Out.WriteLine('{"type":"thread.started","thread_id":"stub-thread-1"}')
            [Console]::Out.WriteLine('{"type":"turn.started"}')
            [Console]::Out.WriteLine('{"type":"error","message":"You have hit your usage limit. Try again later."}')
            [Console]::Out.WriteLine('{"type":"turn.failed","error":{"message":"usage limit reached"}}')
            exit 1
        }
    }
    # a fresh window only: a reset that is already frozen in the future stays
    if ([bool](Get-StubValue 'anchor' $false) -and $statePath -and ($null -eq (Get-AnchoredReset))) {
        $c = Get-StubValue 'r5' $null
        if (($null -eq $c) -or ([long]$c -le $now)) {
            [System.IO.File]::WriteAllText($statePath, ('{"r5":' + ($now + 18000) + '}'))
            Write-StubCall ('anchored ' + ($now + 18000))
        }
    }
    [Console]::Out.WriteLine('{"type":"thread.started","thread_id":"stub-thread-1"}')
    [Console]::Out.WriteLine('{"type":"turn.started"}')
    [Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"hi"}}')
    [Console]::Out.WriteLine('{"type":"turn.completed","usage":{"input_tokens":16900,"cached_input_tokens":12000,"output_tokens":5,"reasoning_output_tokens":0}}')
    exit 0
}

Exit-Usage ($rest -join ' ')
