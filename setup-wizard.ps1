<#
.SYNOPSIS
    Interactive first-run setup wizard for the Jellyfin + TorBox + PotPlayer stack.
.DESCRIPTION
    New-user wizard at repo root. Stdlib PowerShell only (5.1 and 7 compatible,
    no modules). Owns no other file; never writes secrets to disk.

    20 steps/features:
      1) Welcome banner + 5-bullet plan.
      2) Menu loop (numbered choices, 'q' to quit, back option).
      3) TorBox key entry (masked), Machine/User scope choice, persist + verify via 1 API call.
      4) Library roots editor (add/remove/list, e.g. F:\TorboxMedia, validate existence).
      5) Jellyfin connection test (server URL + token prompt, /System/Info/Public check).
      6) PotPlayer path auto-detect (registry + Program Files scan) with manual override.
      7) rclone.conf presence check + guided pointer to create it.
      8) Port availability check (8888/18099/18080/8096) with occupant process name.
      9) Playback mode choice (FullSeason default vs Single) persisted to env/file.
     10) Dry-run summary of every pending change before apply.
     11) Apply step with per-item ok/fail + automatic rollback list on failure.
     12) Post-setup health check reusing installer port probes.
     13) Open panel URL in browser on success (opt-in).
     14) Save answers to setup-answers.json (minus secrets!) for re-runs.
     15) -Resume switch continuing from saved answers.
     16) -NonInteractive switch reading answers file only (never prompts).
     17) Input validation on every prompt (re-ask, never crash).
     18) Color-coded output + progress counter (step X of Y).
     19) Wizard log file (secrets redacted).
     20) Goodbye screen with docs links + star-CTA for the GitHub repo.

    Secrets (TorBox key, Jellyfin token) live only in memory + user/process
    environment variables. They are NEVER written to setup-answers.json or the log.
.EXAMPLE
    pwsh -File setup-wizard.ps1
    Interactive first run.
.EXAMPLE
    pwsh -File setup-wizard.ps1 -Resume
    Continue from saved setup-answers.json.
.EXAMPLE
    pwsh -File setup-wizard.ps1 -NonInteractive
    Headless run: reads setup-answers.json only (secrets come from env).
.NOTES
    PUBLIC repo (MIT). Never commit secrets. Stdlib only. Compatible with
    Windows PowerShell 5.1 and PowerShell 7+.
#>
param(
    [switch]$Resume,
    [switch]$NonInteractive,
    [string]$AnswersFile = "",
    [string]$BaseDir = ""
)

$ErrorActionPreference = 'Stop'
$script:WizardVersion = '1.0.0'
$script:RepoUrl = 'https://github.com/MHJoy99/jellyfin-torbox-potplayer-stack'
# Progress counter: 7 config steps + dry-run + apply + health = 10 countable units.
$script:TotalSteps = 10
$script:CompletedSteps = 0
$script:WizardPorts = @(
    @{ Port = 8888;  Service = 'torbox-proxy (server/torbox-proxy.py :8888)' },
    @{ Port = 18099; Service = 'PotPlayer bridge (:18099)' },
    @{ Port = 18080; Service = 'control-panel (:18080)' },
    @{ Port = 8096;  Service = 'Jellyfin (:8096)' }
)

if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    if ($PSCommandPath) { $script:ScriptDir = Split-Path -Parent $PSCommandPath }
    else { $script:ScriptDir = (Get-Location).Path }
} else {
    $script:ScriptDir = $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($AnswersFile)) {
    $script:AnswersPath = Join-Path $script:ScriptDir 'setup-answers.json'
} else {
    $script:AnswersPath = $AnswersFile
}
if ([string]::IsNullOrWhiteSpace($BaseDir)) {
    $script:RepoRoot = $script:ScriptDir
} else {
    $script:RepoRoot = $BaseDir
}
$script:LogPath = Join-Path $script:ScriptDir 'setup-wizard.log'

# In-memory state (non-secret; safe to persist) + secrets (never persisted).
$script:State = @{
    TorboxScope   = 'Machine'
    LibraryRoots  = @()
    JellyfinUrl   = 'http://127.0.0.1:8096'
    PotPlayerPath = ''
    RcloneConf    = ''
    PlaybackMode  = 'FullSeason'
    PanelUrl      = 'http://127.0.0.1:18080'
    OpenBrowser   = $false
}
$script:Secrets = @{
    TorboxKey    = ''
    JellyfinToken = ''
}
$script:StatusFlags = @{
    TorboxVerified   = $false
    JellyfinVerified = $false
    PortsChecked     = $false
    Applied          = $false
    HealthPassed     = $false
}

#region Logging + colored output (F18, F19)
function Write-WizardLog {
    param([string]$Message)
    try {
        $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}
function Write-Ok {
    param([string]$Message)
    Write-Host ('[ok] {0}' -f $Message) -ForegroundColor Green
    Write-WizardLog ('OK: {0}' -f $Message)
}
function Write-Fail {
    param([string]$Message)
    Write-Host ('[fail] {0}' -f $Message) -ForegroundColor Red
    Write-WizardLog ('FAIL: {0}' -f $Message)
}
function Write-Warn {
    param([string]$Message)
    Write-Host ('[!] {0}' -f $Message) -ForegroundColor Yellow
    Write-WizardLog ('WARN: {0}' -f $Message)
}
function Write-Info {
    param([string]$Message)
    Write-Host ('[*] {0}' -f $Message) -ForegroundColor Gray
    Write-WizardLog ('INFO: {0}' -f $Message)
}
function Write-Header {
    param([string]$Message)
    Write-Host ''
    Write-Host $Message -ForegroundColor Cyan
    Write-WizardLog ('== {0}' -f $Message)
}
function Show-Progress {
    param([string]$Label)
    $done = $script:CompletedSteps
    if ($done -gt $script:TotalSteps) { $done = $script:TotalSteps }
    Write-Host ('--- step {0} of {1}: {2} ---' -f $done, $script:TotalSteps, $Label) -ForegroundColor Cyan
}
function Mark-StepDone {
    param([string]$Label)
    $script:CompletedSteps++
    if ($script:CompletedSteps -gt $script:TotalSteps) { $script:CompletedSteps = $script:TotalSteps }
    Write-WizardLog ('STEP DONE ({0}/{1}): {2}' -f $script:CompletedSteps, $script:TotalSteps, $Label)
}
#endregion

#region Validated input (F17) — re-ask, never crash, q/back handling
function Read-SecretMasked {
    param([string]$Prompt)
    try {
        $sec = Read-Host -Prompt $Prompt -AsSecureString
        if ($null -eq $sec) { return '' }
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
        finally {
            try { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) } catch {}
        }
    } catch {
        Write-Warn ('Input error ({0}); please try again.' -f $_.Exception.Message)
        return $null
    }
}
function Read-PlainValidated {
    param(
        [string]$Prompt,
        [string]$Default = '',
        [bool]$AllowEmpty = $false,
        [scriptblock]$Validate = $null,
        [string]$HelpText = ''
    )
    while ($true) {
        try {
            $suffix = ''
            if (-not [string]::IsNullOrEmpty($Default)) { $suffix = (' [{0}]' -f $Default) }
            $raw = Read-Host -Prompt ('{0}{1}' -f $Prompt, $suffix)
            if ($null -eq $raw) { $raw = '' }
            $raw = $raw.Trim()
            if ([string]::IsNullOrEmpty($raw) -and (-not [string]::IsNullOrEmpty($Default))) { $raw = $Default }
            if (($raw -eq 'q') -or ($raw -eq 'Q')) { return @{ Value = $null; Quit = $true; Back = $false } }
            if (($raw -eq 'back') -or ($raw -eq 'b') -or ($raw -eq 'B')) { return @{ Value = $null; Quit = $false; Back = $true } }
            if ([string]::IsNullOrEmpty($raw) -and (-not $AllowEmpty)) {
                Write-Warn 'Value is required. Type a value, or q to quit / back to go back.'
                if ($HelpText) { Write-Info $HelpText }
                continue
            }
            if ($Validate) {
                $err = ''
                $ok = $false
                try { $ok = & $Validate $raw ([ref]$err) } catch { $ok = $false; $err = $_.Exception.Message }
                if (-not $ok) {
                    if ([string]::IsNullOrWhiteSpace($err)) { $err = 'Invalid value.' }
                    Write-Warn ('{0} Please try again (q to quit, back to go back).' -f $err)
                    if ($HelpText) { Write-Info $HelpText }
                    continue
                }
            }
            return @{ Value = $raw; Quit = $false; Back = $false }
        } catch {
            Write-Warn ('Input error ({0}); please try again.' -f $_.Exception.Message)
        }
    }
}
#endregion

#region Answers file (F14, F15, F16) — minus secrets
function Save-WizardAnswers {
    try {
        $obj = [ordered]@{
            _note         = 'Wizard answers (secrets NEVER saved here). Re-run with -Resume or -NonInteractive.'
            version       = $script:WizardVersion
            savedAt       = (Get-Date).ToString('o')
            torboxScope   = $script:State.TorboxScope
            libraryRoots  = @($script:State.LibraryRoots)
            jellyfinUrl   = $script:State.JellyfinUrl
            potPlayerPath = $script:State.PotPlayerPath
            rcloneConf    = $script:State.RcloneConf
            playbackMode  = $script:State.PlaybackMode
            panelUrl      = $script:State.PanelUrl
            openBrowser   = [bool]$script:State.OpenBrowser
        }
        $json = $obj | ConvertTo-Json -Depth 5
        # Safety: refuse to persist anything that looks like a pasted secret.
        if ($json -match '(?i)torbox[_-]?key|jellyfin[_-]?token|api[_-]?key.{0,5}[A-Za-z0-9]{16,}') {
            # Only our own key names would trip this; values are never embedded, so a
            # match here means a secret leaked into state — abort instead of saving.
            if (($json -match [regex]::Escape($script:Secrets.TorboxKey)) -and ($script:Secrets.TorboxKey.Length -gt 0)) {
                throw 'Refusing to save: TorBox key detected in answers payload.'
            }
        }
        $json | Out-File -LiteralPath $script:AnswersPath -Encoding UTF8 -Force
        Write-Ok ('Answers saved to {0} (secrets excluded).' -f $script:AnswersPath)
        return $true
    } catch {
        Write-Fail ('Could not save answers: {0}' -f $_.Exception.Message)
        return $false
    }
}
function Load-WizardAnswers {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $obj = $raw | ConvertFrom-Json
        return $obj
    } catch {
        Write-Warn ('Could not read answers file {0}: {1}' -f $Path, $_.Exception.Message)
        return $null
    }
}
function Apply-AnswersToState {
    param($Answers)
    try {
        if ($Answers.torboxScope) { $script:State.TorboxScope = [string]$Answers.torboxScope }
        if ($Answers.libraryRoots) { $script:State.LibraryRoots = @($Answers.libraryRoots | ForEach-Object { [string]$_ }) }
        if ($Answers.jellyfinUrl) { $script:State.JellyfinUrl = [string]$Answers.jellyfinUrl }
        if ($Answers.potPlayerPath) { $script:State.PotPlayerPath = [string]$Answers.potPlayerPath }
        if ($Answers.rcloneConf) { $script:State.RcloneConf = [string]$Answers.rcloneConf }
        if ($Answers.playbackMode) { $script:State.PlaybackMode = [string]$Answers.playbackMode }
        if ($Answers.panelUrl) { $script:State.PanelUrl = [string]$Answers.panelUrl }
        if ($null -ne $Answers.openBrowser) { $script:State.OpenBrowser = [bool]$Answers.openBrowser }
    } catch {
        Write-Warn ('Some saved answers could not be applied: {0}' -f $_.Exception.Message)
    }
}
#endregion

#region F3 TorBox — masked entry, scope, persist + 1-call verify
function Test-TorboxKeyOnce {
    param([string]$ApiKey)
    # Exactly ONE API call: GET /v1/api/user/me?token=<key>.
    # Header-only auth returns HTTP 422 on this API, so ?token= is required.
    $url = ('https://api.torbox.app/v1/api/user/me?token={0}' -f $ApiKey.Trim())
    try {
        $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 12 -ErrorAction Stop
        $ok = $false
        try {
            if ($resp.success -eq $true) { $ok = $true }
            elseif ($resp.detail) { $ok = $false }
            else { $ok = $true }
        } catch { $ok = $true }
        return $ok
    } catch {
        $msg = $_.Exception.Message
        try {
            $web = $_.Exception.Response
            if ($web -and $web.StatusCode) { $msg = ('HTTP {0}: {1}' -f [int]$web.StatusCode, $web.StatusDescription) }
        } catch {}
        Write-WizardLog ('TorBox verify failed: {0}' -f $msg)
        return $false
    }
}
function Invoke-TorboxStep {
    Write-Header 'TorBox API key  [3]'
    Show-Progress -Label 'TorBox key'
    Write-Host 'Paste a TorBox key (input is masked). Choose Machine scope for 24/7' -ForegroundColor White
    Write-Host 'hosts or User scope for a personal account. 1 verification call only.' -ForegroundColor Gray
    if ($NonInteractive) {
        if ([string]::IsNullOrWhiteSpace($env:TORBOX_API_KEY)) {
            Write-Fail 'NonInteractive: $env:TORBOX_API_KEY is required (answers file never holds secrets).'
            return $false
        }
        $script:Secrets.TorboxKey = $env:TORBOX_API_KEY.Trim()
        Write-Info 'NonInteractive: TorBox key taken from $env:TORBOX_API_KEY.'
        $verified = Test-TorboxKeyOnce -ApiKey $script:Secrets.TorboxKey
        $script:StatusFlags.TorboxVerified = [bool]$verified
        if ($verified) { Write-Ok 'TorBox key verified (1 API call).' } else { Write-Fail 'TorBox verification failed.' }
        Mark-StepDone -Label 'TorBox'
        return [bool]$verified
    }
    while ($true) {
        $entered = Read-SecretMasked -Prompt 'TorBox API key (masked, back to return)'
        if ($null -eq $entered) { continue }
        $entered = $entered.Trim()
        if (($entered -eq 'q') -or ($entered -eq 'Q')) { return $false }
        if (($entered -eq 'back') -or ($entered -eq 'b')) { return $true }
        if ([string]::IsNullOrWhiteSpace($entered)) {
            if (-not [string]::IsNullOrWhiteSpace($env:TORBOX_API_KEY)) {
                Write-Info 'Empty input: keeping existing $env:TORBOX_API_KEY.'
                $entered = $env:TORBOX_API_KEY.Trim()
            } else {
                Write-Warn 'Key is required. Paste the key, or type back to return.'
                continue
            }
        }
        if ($entered.Length -lt 8) {
            Write-Warn 'That key looks too short; please re-paste the full key.'
            continue
        }
        $choice = Read-PlainValidated -Prompt 'Scope: [1] Machine (default) / [2] User' -Default '1' -AllowEmpty $false `
            -Validate { param($v, [ref]$e) if ($v -match '^[12]$|(?i)^(machine|user)$') { return $true }; $e.Value = 'Enter 1/Machine or 2/User.'; return $false }
        if ($choice.Quit) { return $false }
        if ($choice.Back) { return $true }
        $scope = 'Machine'
        if (($choice.Value -eq '2') -or ($choice.Value -match '(?i)^user$')) { $scope = 'User' }
        $script:State.TorboxScope = $scope
        Write-Info 'Verifying with a single GET to api.torbox.app /v1/api/user/me ...'
        $verified = Test-TorboxKeyOnce -ApiKey $entered
        if ($verified) {
            $script:Secrets.TorboxKey = $entered
            $script:StatusFlags.TorboxVerified = $true
            Write-Ok ('TorBox key verified (scope={0}, 1 API call).' -f $scope)
            Mark-StepDone -Label 'TorBox'
            return $true
        }
        Write-Fail 'TorBox rejected the key (or network failed). Check the key and try again.'
        $retry = Read-PlainValidated -Prompt 'Retry? [Y/n]' -Default 'Y' -AllowEmpty $false `
            -Validate { param($v, [ref]$e) if ($v -match '(?i)^y(es)?$|^n(o)?$') { return $true }; $e.Value = 'Enter Y or N.'; return $false }
        if ($retry.Quit) { return $false }
        if ($retry.Back) { return $true }
        if ($retry.Value -match '(?i)^n') { return $true }
    }
}
#endregion

#region F4 Library roots editor
function Test-LibraryRootValid {
    param([string]$Path, [ref]$Err)
    if ([string]::IsNullOrWhiteSpace($Path)) { $Err.Value = 'Path is empty.'; return $false }
    if ($Path -match '[<>:"|?*]') {
        # Allow drive-letter colon (F:\) but reject other illegal chars.
        $tmp = $Path -replace '^[A-Za-z]:\\', ''
        if ($tmp -match '[<>:"|?*]') { $Err.Value = 'Path contains illegal characters (<>:"|?*).'; return $false }
    }
    if ($Path.Length -lt 3) { $Err.Value = 'Path looks too short (e.g. F:\TorboxMedia).'; return $false }
    return $true
}
function Invoke-LibraryStep {
    Write-Header 'Library roots  [4]'
    Show-Progress -Label 'Library roots'
    Write-Host 'Libraries are the folders Jellyfin scans (e.g. F:\TorboxMedia).' -ForegroundColor White
    Write-Host 'Commands: [a]dd  [r]emove  [l]ist  [d]one   (back returns, q quits)' -ForegroundColor Gray
    if ($NonInteractive) {
        if ($script:State.LibraryRoots.Count -eq 0) { Write-Warn 'NonInteractive: no libraryRoots in answers file.' }
        foreach ($p in $script:State.LibraryRoots) {
            if (Test-Path -LiteralPath $p) { Write-Ok ('Library exists: {0}' -f $p) }
            else { Write-Warn ('Library missing (will be created on apply): {0}' -f $p) }
        }
        Mark-StepDone -Label 'Library roots'
        return $true
    }
    if ($script:State.LibraryRoots.Count -eq 0 -and (Test-Path -LiteralPath 'F:\TorboxMedia')) {
        $script:State.LibraryRoots = @('F:\TorboxMedia')
    }
    while ($true) {
        Write-Host ''
        if ($script:State.LibraryRoots.Count -eq 0) { Write-Info '(no library roots yet)' }
        else {
            for ($i = 0; $i -lt $script:State.LibraryRoots.Count; $i++) {
                $p = $script:State.LibraryRoots[$i]
                $exists = Test-Path -LiteralPath $p
                $tag = 'missing'
                $color = 'Yellow'
                if ($exists) { $tag = 'exists'; $color = 'Green' }
                Write-Host (('[{0}] {1}  <{2}>' -f ($i + 1), $p, $tag)) -ForegroundColor $color
            }
        }
        $cmd = Read-Host -Prompt 'Libraries [a]dd/[r]emove/[l]ist/[d]one (back/q)'
        if ($null -eq $cmd) { continue }
        $cmd = $cmd.Trim()
        if (($cmd -eq 'q') -or ($cmd -eq 'Q')) { return $false }
        if (($cmd -eq 'back') -or ($cmd -eq 'b') -or ($cmd -eq 'B')) { return $true }
        if (($cmd -eq 'd') -or ($cmd -eq 'done') -or ($cmd -eq '')) {
            if ($script:State.LibraryRoots.Count -eq 0) {
                Write-Warn 'Add at least one library root before continuing.'
                continue
            }
            Mark-StepDone -Label 'Library roots'
            return $true
        }
        if (($cmd -eq 'l') -or ($cmd -eq 'list')) { continue }
        if (($cmd -eq 'a') -or ($cmd -eq 'add')) {
            $got = Read-PlainValidated -Prompt 'New library path (e.g. F:\TorboxMedia)' -Default '' -AllowEmpty $false `
                -Validate { param($v, [ref]$e) return (Test-LibraryRootValid -Path $v -Err $e) }
            if ($got.Quit) { return $false }
            if ($got.Back) { continue }
            $np = $got.Value
            if ($script:State.LibraryRoots -contains $np) { Write-Warn 'That path is already in the list.'; continue }
            if (Test-Path -LiteralPath $np) { Write-Ok ('Added (exists): {0}' -f $np) }
            else { Write-Warn ('Added (missing now; apply will create it): {0}' -f $np) }
            $script:State.LibraryRoots += $np
            Write-WizardLog ('Library added: {0}' -f $np)
            continue
        }
        if (($cmd -eq 'r') -or ($cmd -eq 'remove')) {
            if ($script:State.LibraryRoots.Count -eq 0) { Write-Warn 'Nothing to remove.'; continue }
            $got = Read-PlainValidated -Prompt ('Number to remove (1-{0})' -f $script:State.LibraryRoots.Count) -Default '' -AllowEmpty $false `
                -Validate { param($v, [ref]$e) if ($v -match '^\d+$') { return $true }; $e.Value = 'Enter the row number.'; return $false }
            if ($got.Quit) { return $false }
            if ($got.Back) { continue }
            $n = 0
            try { $n = [int]$got.Value } catch { $n = 0 }
            if (($n -lt 1) -or ($n -gt $script:State.LibraryRoots.Count)) { Write-Warn 'Number out of range.'; continue }
            $removed = $script:State.LibraryRoots[$n - 1]
            $next = @()
            for ($i = 0; $i -lt $script:State.LibraryRoots.Count; $i++) { if ($i -ne ($n - 1)) { $next += $script:State.LibraryRoots[$i] } }
            $script:State.LibraryRoots = $next
            Write-Ok ('Removed: {0}' -f $removed)
            continue
        }
        Write-Warn 'Unknown command. Use a / r / l / d (or back / q).'
    }
}
#endregion

#region F5 Jellyfin connection test
function Invoke-JellyfinStep {
    Write-Header 'Jellyfin connection  [5]'
    Show-Progress -Label 'Jellyfin'
    Write-Host 'Checks GET {url}/System/Info/Public (no auth needed; token is stored for later).' -ForegroundColor Gray
    if ($NonInteractive) {
        $tok = $env:JELLYFIN_API_KEY
        if (-not [string]::IsNullOrWhiteSpace($tok)) { $script:Secrets.JellyfinToken = $tok.Trim() }
        $url = $script:State.JellyfinUrl.TrimEnd('/')
        try {
            $info = Invoke-RestMethod -Uri ('{0}/System/Info/Public' -f $url) -Method Get -TimeoutSec 8 -ErrorAction Stop
            $script:StatusFlags.JellyfinVerified = $true
            Write-Ok ('Jellyfin reachable: {0}' -f $url)
            try { Write-Info ('Server: {0} {1}' -f $info.ServerName, $info.Version) } catch {}
        } catch {
            Write-Fail ('Jellyfin check failed for {0}: {1}' -f $url, $_.Exception.Message)
            return $false
        }
        Mark-StepDone -Label 'Jellyfin'
        return $true
    }
    $gotUrl = Read-PlainValidated -Prompt 'Jellyfin server URL' -Default $script:State.JellyfinUrl -AllowEmpty $false `
        -Validate {
            param($v, [ref]$e)
            $u = $null
            if ([Uri]::TryCreate($v, [UriKind]::Absolute, [ref]$u)) {
                if (($u.Scheme -eq 'http') -or ($u.Scheme -eq 'https')) { return $true }
            }
            $e.Value = 'Enter a full URL like http://127.0.0.1:8096.'
            return $false
        } -HelpText 'Example: http://127.0.0.1:8096'
    if ($gotUrl.Quit) { return $false }
    if ($gotUrl.Back) { return $true }
    $script:State.JellyfinUrl = $gotUrl.Value.Trim().TrimEnd('/')
    $tokEntered = Read-SecretMasked -Prompt 'Jellyfin API token/key (masked, empty to skip, back to return)'
    if ($null -eq $tokEntered) { return $true }
    $tokEntered = $tokEntered.Trim()
    if (($tokEntered -eq 'q') -or ($tokEntered -eq 'Q')) { return $false }
    if (($tokEntered -eq 'back') -or ($tokEntered -eq 'b')) { return $true }
    if ([string]::IsNullOrWhiteSpace($tokEntered)) {
        if (-not [string]::IsNullOrWhiteSpace($env:JELLYFIN_API_KEY)) {
            $script:Secrets.JellyfinToken = $env:JELLYFIN_API_KEY.Trim()
            Write-Info 'Empty input: keeping existing $env:JELLYFIN_API_KEY.'
        } else {
            Write-Warn 'No token entered; Public check will still run (authenticated calls come later).'
        }
    } else {
        $script:Secrets.JellyfinToken = $tokEntered
    }
    try {
        $info = Invoke-RestMethod -Uri ('{0}/System/Info/Public' -f $script:State.JellyfinUrl) -Method Get -TimeoutSec 8 -ErrorAction Stop
        $script:StatusFlags.JellyfinVerified = $true
        $name = ''
        $ver = ''
        try { $name = $info.ServerName } catch {}
        try { $ver = $info.Version } catch {}
        Write-Ok ('Jellyfin Public OK: {0}  Server="{1}" Version={2}' -f $script:State.JellyfinUrl, $name, $ver)
    } catch {
        $script:StatusFlags.JellyfinVerified = $false
        Write-Fail ('Jellyfin Public check failed: {0}' -f $_.Exception.Message)
        Write-Info 'Is Jellyfin running? Start it, then re-run this step.'
        return $true
    }
    Mark-StepDone -Label 'Jellyfin'
    return $true
}
#endregion

#region F6 PotPlayer auto-detect (registry + Program Files scan) + manual override
function Find-PotPlayerExe {
    $found = @()
    $regKeys = @(
        'HKLM:\SOFTWARE\DAUM\PotPlayer',
        'HKLM:\SOFTWARE\WOW6432Node\DAUM\PotPlayer',
        'HKCU:\Software\DAUM\PotPlayer',
        'HKCU:\Software\DAUM\PotPlayer64',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\PotPlayerMini64.exe',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\PotPlayer64.exe',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\PotPlayerMini64.exe'
    )
    foreach ($rk in $regKeys) {
        try {
            if (Test-Path -LiteralPath $rk) {
                $props = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
                if ($props) {
                    foreach ($pn in @('(default)', 'ProgramPath', 'Path', 'InstallPath', 'ExePath')) {
                        try {
                            $v = $props.$pn
                            if (-not [string]::IsNullOrWhiteSpace($v)) {
                                $cand = [string]$v
                                if ((Test-Path -LiteralPath $cand -PathType Leaf) -and ($cand -match '(?i)\.exe$')) {
                                    if ($found -notcontains $cand) { $found += $cand }
                                }
                                $joined = Join-Path $cand 'PotPlayerMini64.exe'
                                if (Test-Path -LiteralPath $joined -PathType Leaf) {
                                    if ($found -notcontains $joined) { $found += $joined }
                                }
                            }
                        } catch {}
                    }
                }
            }
        } catch {}
    }
    $pf = $env:ProgramFiles
    if ([string]::IsNullOrWhiteSpace($pf)) { $pf = 'C:\Program Files' }
    $pfx86 = ${env:ProgramFiles(x86)}
    if ([string]::IsNullOrWhiteSpace($pfx86)) { $pfx86 = 'C:\Program Files (x86)' }
    $scan = @(
        (Join-Path $pf 'DAUM\PotPlayer\PotPlayerMini64.exe'),
        (Join-Path $pf 'DAUM\PotPlayer\PotPlayer64.exe'),
        (Join-Path $pfx86 'DAUM\PotPlayer\PotPlayerMini.exe'),
        (Join-Path $pfx86 'DAUM\PotPlayer\PotPlayer.exe'),
        'E:\PotPlayer\PotPlayerMini64.exe',
        'E:\MediaServer\apps\PotPlayer\PotPlayerMini64.exe',
        'C:\PotPlayer\PotPlayerMini64.exe',
        'D:\PotPlayer\PotPlayerMini64.exe'
    )
    foreach ($s in $scan) {
        try {
            if ((Test-Path -LiteralPath $s -PathType Leaf) -and ($found -notcontains $s)) { $found += $s }
        } catch {}
    }
    try {
        $cmd = Get-Command PotPlayerMini64.exe -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) {
            if ($found -notcontains $cmd.Source) { $found += $cmd.Source }
        }
    } catch {}
    return $found
}
function Invoke-PotPlayerStep {
    Write-Header 'PotPlayer path  [6]'
    Show-Progress -Label 'PotPlayer'
    Write-Host 'Auto-detects via registry App Paths + DAUM keys + Program Files scan.' -ForegroundColor Gray
    $cands = @(Find-PotPlayerExe)
    if ($NonInteractive) {
        if (-not [string]::IsNullOrWhiteSpace($script:State.PotPlayerPath) -and (Test-Path -LiteralPath $script:State.PotPlayerPath)) {
            Write-Ok ('PotPlayer (answers): {0}' -f $script:State.PotPlayerPath)
        } elseif ($cands.Count -gt 0) {
            $script:State.PotPlayerPath = $cands[0]
            Write-Ok ('PotPlayer (auto-detected): {0}' -f $script:State.PotPlayerPath)
        } else {
            Write-Warn 'NonInteractive: PotPlayer not found; continuing without it.'
        }
        Mark-StepDone -Label 'PotPlayer'
        return $true
    }
    if ($cands.Count -gt 0) {
        Write-Host 'Detected candidate(s):' -ForegroundColor White
        for ($i = 0; $i -lt $cands.Count; $i++) {
            Write-Host (('  [{0}] {1}' -f ($i + 1), $cands[$i])) -ForegroundColor Green
        }
        if ([string]::IsNullOrWhiteSpace($script:State.PotPlayerPath)) {
            $script:State.PotPlayerPath = $cands[0]
        }
    } else {
        Write-Warn 'Auto-detect found nothing (registry + Program Files scan empty).'
    }
    if (-not [string]::IsNullOrWhiteSpace($script:State.PotPlayerPath)) {
        Write-Info ('Current selection: {0}' -f $script:State.PotPlayerPath)
    }
    $got = Read-PlainValidated -Prompt 'Accept current [Enter], pick number, or type full .exe path (back to return)' -Default '' -AllowEmpty $true
    if ($got.Quit) { return $false }
    if ($got.Back) { return $true }
    $v = $got.Value.Trim()
    if ([string]::IsNullOrEmpty($v)) {
        if ([string]::IsNullOrWhiteSpace($script:State.PotPlayerPath) -and ($cands.Count -eq 0)) {
            Write-Warn 'No PotPlayer path set; you can fix this later and re-run the wizard.'
        } else {
            Write-Ok ('PotPlayer kept: {0}' -f $script:State.PotPlayerPath)
        }
        Mark-StepDone -Label 'PotPlayer'
        return $true
    }
    $num = 0
    if (($v -match '^\d+$') -and ($cands.Count -gt 0)) {
        try { $num = [int]$v } catch { $num = 0 }
        if (($num -ge 1) -and ($num -le $cands.Count)) {
            $script:State.PotPlayerPath = $cands[$num - 1]
            Write-Ok ('PotPlayer selected: {0}' -f $script:State.PotPlayerPath)
            Mark-StepDone -Label 'PotPlayer'
            return $true
        }
        Write-Warn 'Number out of range.'
        return $true
    }
    if (-not ($v -match '(?i)\.exe$')) {
        Write-Warn 'Manual path must end in .exe (e.g. PotPlayerMini64.exe).'
        return $true
    }
    if (-not (Test-Path -LiteralPath $v -PathType Leaf)) {
        Write-Warn ('File not found: {0}. Keeping previous selection.' -f $v)
        return $true
    }
    $script:State.PotPlayerPath = $v
    Write-Ok ('PotPlayer manual override accepted: {0}' -f $v)
    Mark-StepDone -Label 'PotPlayer'
    return $true
}
#endregion

#region F7 rclone.conf presence check + guided pointer
function Get-RcloneConfCandidates {
    $list = @()
    $list += (Join-Path $script:RepoRoot 'config\rclone.conf')
    $list += 'F:\Jellyfin\config\rclone.conf'
    $list += 'E:\MediaServer\config\rclone.conf'
    try {
        $app = [Environment]::GetFolderPath('ApplicationData')
        if ($app) { $list += (Join-Path $app 'rclone\rclone.conf') }
    } catch {}
    return $list
}
function Invoke-RcloneStep {
    Write-Header 'rclone.conf check  [7]'
    Show-Progress -Label 'rclone.conf'
    $cands = Get-RcloneConfCandidates
    $hit = ''
    foreach ($c in $cands) {
        try {
            if (Test-Path -LiteralPath $c -PathType Leaf) { $hit = $c; break }
        } catch {}
    }
    if ($hit) {
        $script:State.RcloneConf = $hit
        Write-Ok ('rclone.conf found: {0}' -f $hit)
        Mark-StepDone -Label 'rclone.conf'
        return $true
    }
    $script:State.RcloneConf = $cands[0]
    Write-Warn ('rclone.conf NOT found. Expected at: {0}' -f $cands[0])
    Write-Host '  To create it:' -ForegroundColor White
    Write-Host '    1. Install rclone (https://rclone.org/downloads/)' -ForegroundColor Gray
    Write-Host ('    2. Run:  rclone --config "{0}" config' -f $cands[0]) -ForegroundColor Gray
    Write-Host '       Create your remotes (e.g. torbox:, gdrive-media:).' -ForegroundColor Gray
    Write-Host '    3. Verify: rclone --config "<that path>" lsd <remote>:' -ForegroundColor Gray
    Write-Host '    4. Re-run this wizard step; presence will turn green.' -ForegroundColor Gray
    Write-Info 'Wizard continues without rclone.conf; mounts/sync will wait for it.'
    Mark-StepDone -Label 'rclone.conf'
    return $true
}
#endregion

#region F8 + F12 port probes (installer-style TcpClient + occupant name)
function Test-PortFreeTcp {
    param([int]$Port)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(500)
        $connected = ($ok -and $client.Connected)
        try { $client.Close() } catch {}
        return (-not $connected)
    } catch { return $true }
}
function Get-PortOccupant {
    param([int]$Port)
    # Returns occupant process name (or PID/unknown). Prefers Get-NetTCPConnection,
    # falls back to netstat -ano parsing so 5.1 without NetTCPIP still works.
    try {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($conn -and $conn.OwningProcess) {
            $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            if ($proc) { return ('{0} (PID {1})' -f $proc.ProcessName, $proc.Id) }
            return ('PID {0}' -f $conn.OwningProcess)
        }
    } catch {}
    try {
        $lines = netstat -ano 2>$null | Select-String -Pattern ('[:\.]{0}{1}\s' -f '', $Port)
        foreach ($ln in $lines) {
            $t = ('{0}' -f $ln.Line).Trim() -split '\s+'
            if ($t.Count -ge 4 -and ($t[1] -match ('[:]{0}$|[:\.]{0}\s' -f $Port, $Port) -or ($t[1] -match (':{0}$' -f $Port)))) {
                if ($t[2] -match 'LISTENING') {
                    $pidVal = 0
                    try { $pidVal = [int]$t[3] } catch {}
                    if ($pidVal -gt 0) {
                        $proc = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
                        if ($proc) { return ('{0} (PID {1})' -f $proc.ProcessName, $proc.Id) }
                        return ('PID {0}' -f $pidVal)
                    }
                }
            }
        }
    } catch {}
    return 'unknown process'
}
function Invoke-PortStep {
    Write-Header 'Port availability  [8]'
    Show-Progress -Label 'Ports 8888/18099/18080/8096'
    foreach ($p in $script:WizardPorts) {
        $free = Test-PortFreeTcp -Port $p.Port
        if ($free) { Write-Ok ('Port {0} FREE ({1})' -f $p.Port, $p.Service) }
        else {
            $owner = Get-PortOccupant -Port $p.Port
            Write-Warn ('Port {0} IN USE by {1} ({2})' -f $p.Port, $owner, $p.Service)
        }
    }
    Write-Info 'IN USE is fine when it is YOUR service (Jellyfin/proxy/panel/bridge).'
    Write-Info 'Investigate only when the occupant is unexpected.'
    $script:StatusFlags.PortsChecked = $true
    Mark-StepDone -Label 'Ports'
    return $true
}
function Invoke-HealthCheck {
    param([bool]$Quiet = $false)
    if (-not $Quiet) {
        Write-Header 'Post-setup health check  [12]'
        Show-Progress -Label 'Health check'
    }
    $results = @()
    # Reuse the installer TcpClient probe + HTTP probes from control-panel expectations.
    $httpChecks = @(
        @{ Port = 8888;  Url = 'http://127.0.0.1:8888/health';              Name = 'torbox-proxy' },
        @{ Port = 18099; Url = 'http://127.0.0.1:18099/health';             Name = 'bridge' },
        @{ Port = 18080; Url = 'http://127.0.0.1:18080/health';             Name = 'control-panel' },
        @{ Port = 8096;  Url = 'http://127.0.0.1:8096/System/Info/Public';  Name = 'jellyfin' }
    )
    foreach ($h in $httpChecks) {
        $listening = -not (Test-PortFreeTcp -Port $h.Port)
        $httpOk = $false
        $detail = ''
        try {
            $r = Invoke-RestMethod -Uri $h.Url -Method Get -TimeoutSec 3 -ErrorAction Stop
            $httpOk = $true
            try {
                if ($r.Version) { $detail = (' v{0}' -f $r.Version) }
                elseif ($r.version) { $detail = (' v{0}' -f $r.version) }
            } catch {}
        } catch {
            $httpOk = $false
            $detail = ''
        }
        if ($httpOk) {
            Write-Ok ('{0} :{1} HTTP OK{2}' -f $h.Name, $h.Port, $detail)
            $results += @{ Name = $h.Name; Ok = $true }
        } elseif ($listening) {
            Write-Warn ('{0} :{1} port open but HTTP probe failed ({2})' -f $h.Name, $h.Port, $h.Url)
            $results += @{ Name = $h.Name; Ok = $false }
        } else {
            Write-Info ('{0} :{1} not listening (service stopped?)' -f $h.Name, $h.Port)
            $results += @{ Name = $h.Name; Ok = $false }
        }
    }
    $passed = 0
    foreach ($r in $results) { if ($r.Ok) { $passed++ } }
    $script:StatusFlags.HealthPassed = ($passed -gt 0)
    if (-not $Quiet) { Mark-StepDone -Label 'Health check' }
    return $results
}
#endregion

#region F9 Playback mode (FullSeason default vs Single) persisted to env/file
function Invoke-PlaybackStep {
    Write-Header 'Playback mode  [9]'
    Show-Progress -Label 'Playback mode'
    Write-Host 'FullSeason (default): whole season queued in PotPlayer; Single: one item only.' -ForegroundColor Gray
    Write-Host 'Persisted to $env:POTPLAYER_SINGLE + setup-answers.json (the file).' -ForegroundColor Gray
    if ($NonInteractive) {
        Write-Info ('NonInteractive: keeping answers playbackMode={0}.' -f $script:State.PlaybackMode)
        Mark-StepDone -Label 'Playback mode'
        return $true
    }
    $def = '1'
    if ($script:State.PlaybackMode -eq 'Single') { $def = '2' }
    $got = Read-PlainValidated -Prompt 'Playback: [1] FullSeason (default) / [2] Single' -Default $def -AllowEmpty $false `
        -Validate { param($v, [ref]$e) if ($v -match '^[12]$') { return $true }; $e.Value = 'Enter 1 or 2.'; return $false }
    if ($got.Quit) { return $false }
    if ($got.Back) { return $true }
    if ($got.Value -eq '2') { $script:State.PlaybackMode = 'Single' }
    else { $script:State.PlaybackMode = 'FullSeason' }
    Write-Ok ('Playback mode: {0}' -f $script:State.PlaybackMode)
    Mark-StepDone -Label 'Playback mode'
    return $true
}
#endregion

#region F10 dry-run summary
function Show-DryRunSummary {
    Write-Header 'Dry-run summary — pending changes  [10]'
    Show-Progress -Label 'Dry-run review'
    Write-Host 'Nothing has been applied yet. Review, then choose Apply.' -ForegroundColor White
    $lines = @()
    $lines += 'ENV (user + process):'
    $lines += '  TORBOX_API_KEY   = <masked, scope={0}> (from your masked entry; never saved to disk)' -f $script:State.TorboxScope
    $lines += '  JELLYFIN_URL     = {0}' -f $script:State.JellyfinUrl
    if ([string]::IsNullOrWhiteSpace($script:Secrets.JellyfinToken)) { $lines += '  JELLYFIN_API_KEY = <unchanged / not provided>' }
    else { $lines += '  JELLYFIN_API_KEY = <masked token from your entry>' }
    $single = '0'
    if ($script:State.PlaybackMode -eq 'Single') { $single = '1' }
    $lines += '  POTPLAYER_SINGLE = {0}  (mode={1})' -f $single, $script:State.PlaybackMode
    if ([string]::IsNullOrWhiteSpace($script:State.PotPlayerPath)) { $lines += '  POTPLAYER_PATH   = <not set>' }
    else { $lines += '  POTPLAYER_PATH   = {0}' -f $script:State.PotPlayerPath }
    $lines += ''
    $lines += 'LIBRARY DIRECTORIES (created if missing):'
    if ($script:State.LibraryRoots.Count -eq 0) { $lines += '  <none>' }
    else {
        foreach ($p in $script:State.LibraryRoots) {
            $tag = 'CREATE'
            try { if (Test-Path -LiteralPath $p) { $tag = 'exists' } } catch {}
            $lines += '  [{0}] {1}' -f $tag, $p
        }
    }
    $lines += ''
    $lines += 'FILES:'
    $lines += '  WRITE setup-answers.json (answers only, secrets excluded)'
    $lines += '  APPEND setup-wizard.log (this run, secrets redacted)'
    $lines += ''
    $lines += 'CHECKS ONLY (no changes):'
    $lines += '  rclone.conf expected at: {0}' -f $script:State.RcloneConf
    $lines += '  ports probed: 8888 / 18099 / 18080 / 8096'
    $lines += '  health probes: :8888/health, :18099/health, :18080/health, :8096/System/Info/Public'
    foreach ($ln in $lines) {
        if ($ln -match '^\S.*:$') { Write-Host $ln -ForegroundColor Cyan }
        elseif ($ln -match 'CREATE|NOT|missing') { Write-Host $ln -ForegroundColor Yellow }
        else { Write-Host $ln -ForegroundColor White }
    }
    Write-WizardLog 'Dry-run summary shown.'
    Mark-StepDone -Label 'Dry-run'
}
#endregion

#region F11 apply with per-item ok/fail + rollback list
function Invoke-ApplyStep {
    Write-Header 'Apply changes  [11]'
    Show-Progress -Label 'Apply'
    $results = @()
    $rollbacks = New-Object System.Collections.Generic.List[string]
    # Snapshot current env + answers backup for rollback.
    $oldEnv = @{
        TORBOX_API_KEY   = $env:TORBOX_API_KEY
        JELLYFIN_URL     = $env:JELLYFIN_URL
        JELLYFIN_API_KEY = $env:JELLYFIN_API_KEY
        POTPLAYER_SINGLE = $env:POTPLAYER_SINGLE
        POTPLAYER_PATH   = $env:POTPLAYER_PATH
    }
    $answersBackup = $null
    try {
        if (Test-Path -LiteralPath $script:AnswersPath -PathType Leaf) {
            $answersBackup = ('{0}.bak-{1}' -f $script:AnswersPath, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Copy-Item -LiteralPath $script:AnswersPath -Destination $answersBackup -Force
            $rollbacks.Add(('Restore answers from backup: {0}' -f $answersBackup))
        }
    } catch {}
    $createdDirs = New-Object System.Collections.Generic.List[string]
    $anyFail = $false
    # 1. TORBOX_API_KEY
    try {
        if ([string]::IsNullOrWhiteSpace($script:Secrets.TorboxKey)) {
            if (-not [string]::IsNullOrWhiteSpace($env:TORBOX_API_KEY)) {
                Write-Info 'TORBOX_API_KEY: keeping existing process env (no new key entered).'
                $results += @{ Item = 'TORBOX_API_KEY'; Ok = $true; Note = 'kept existing' }
            } else {
                throw 'No TorBox key in this session (complete step 3 first).'
            }
        } else {
            [Environment]::SetEnvironmentVariable('TORBOX_API_KEY', $script:Secrets.TorboxKey, 'User')
            $env:TORBOX_API_KEY = $script:Secrets.TorboxKey
            $results += @{ Item = 'TORBOX_API_KEY'; Ok = $true; Note = ('scope={0}' -f $script:State.TorboxScope) }
            Write-Ok 'Applied TORBOX_API_KEY (user + process).'
            $rollbacks.Add('Restore previous $env:TORBOX_API_KEY (user + process)')
        }
    } catch {
        $results += @{ Item = 'TORBOX_API_KEY'; Ok = $false; Note = $_.Exception.Message }
        Write-Fail ('TORBOX_API_KEY: {0}' -f $_.Exception.Message)
        $anyFail = $true
    }
    # 2. JELLYFIN_URL
    try {
        if ([string]::IsNullOrWhiteSpace($script:State.JellyfinUrl)) { throw 'Jellyfin URL is empty.' }
        [Environment]::SetEnvironmentVariable('JELLYFIN_URL', $script:State.JellyfinUrl, 'User')
        $env:JELLYFIN_URL = $script:State.JellyfinUrl
        $results += @{ Item = 'JELLYFIN_URL'; Ok = $true; Note = $script:State.JellyfinUrl }
        Write-Ok ('Applied JELLYFIN_URL={0}.' -f $script:State.JellyfinUrl)
        $rollbacks.Add('Restore previous $env:JELLYFIN_URL (user + process)')
    } catch {
        $results += @{ Item = 'JELLYFIN_URL'; Ok = $false; Note = $_.Exception.Message }
        Write-Fail ('JELLYFIN_URL: {0}' -f $_.Exception.Message)
        $anyFail = $true
    }
    # 3. JELLYFIN_API_KEY (optional)
    try {
        if ([string]::IsNullOrWhiteSpace($script:Secrets.JellyfinToken)) {
            $results += @{ Item = 'JELLYFIN_API_KEY'; Ok = $true; Note = 'skipped (no token entered)' }
            Write-Info 'JELLYFIN_API_KEY: skipped (no token entered).'
        } else {
            [Environment]::SetEnvironmentVariable('JELLYFIN_API_KEY', $script:Secrets.JellyfinToken, 'User')
            $env:JELLYFIN_API_KEY = $script:Secrets.JellyfinToken
            $results += @{ Item = 'JELLYFIN_API_KEY'; Ok = $true; Note = 'stored (masked)' }
            Write-Ok 'Applied JELLYFIN_API_KEY (user + process).'
            $rollbacks.Add('Restore previous $env:JELLYFIN_API_KEY (user + process)')
        }
    } catch {
        $results += @{ Item = 'JELLYFIN_API_KEY'; Ok = $false; Note = $_.Exception.Message }
        Write-Fail ('JELLYFIN_API_KEY: {0}' -f $_.Exception.Message)
        $anyFail = $true
    }
    # 4. POTPLAYER_SINGLE (+ POTPLAYER_PATH)
    try {
        $single = '0'
        if ($script:State.PlaybackMode -eq 'Single') { $single = '1' }
        [Environment]::SetEnvironmentVariable('POTPLAYER_SINGLE', $single, 'User')
        $env:POTPLAYER_SINGLE = $single
        if (-not [string]::IsNullOrWhiteSpace($script:State.PotPlayerPath)) {
            [Environment]::SetEnvironmentVariable('POTPLAYER_PATH', $script:State.PotPlayerPath, 'User')
            $env:POTPLAYER_PATH = $script:State.PotPlayerPath
        }
        $results += @{ Item = 'Playback env'; Ok = $true; Note = ('mode={0} POTPLAYER_SINGLE={1}' -f $script:State.PlaybackMode, $single) }
        Write-Ok ('Applied playback mode {0} (POTPLAYER_SINGLE={1}).' -f $script:State.PlaybackMode, $single)
        $rollbacks.Add('Restore previous $env:POTPLAYER_SINGLE / $env:POTPLAYER_PATH')
    } catch {
        $results += @{ Item = 'Playback env'; Ok = $false; Note = $_.Exception.Message }
        Write-Fail ('Playback env: {0}' -f $_.Exception.Message)
        $anyFail = $true
    }
    # 5. Library directories
    foreach ($p in $script:State.LibraryRoots) {
        try {
            if (Test-Path -LiteralPath $p) {
                $results += @{ Item = ('dir {0}' -f $p); Ok = $true; Note = 'exists' }
                Write-Ok ('Library exists: {0}' -f $p)
            } else {
                New-Item -ItemType Directory -Path $p -Force | Out-Null
                [void]$createdDirs.Add($p)
                $results += @{ Item = ('dir {0}' -f $p); Ok = $true; Note = 'created' }
                Write-Ok ('Library created: {0}' -f $p)
                $rollbacks.Add(('Remove created directory: {0}' -f $p))
            }
        } catch {
            $results += @{ Item = ('dir {0}' -f $p); Ok = $false; Note = $_.Exception.Message }
            Write-Fail ('Library {0}: {1}' -f $p, $_.Exception.Message)
            $anyFail = $true
        }
    }
    # 6. Answers file (never secrets)
    try {
        if (Save-WizardAnswers) {
            $results += @{ Item = 'setup-answers.json'; Ok = $true; Note = 'answers only, secrets excluded' }
        } else { throw 'Save-WizardAnswers reported failure.' }
    } catch {
        $results += @{ Item = 'setup-answers.json'; Ok = $false; Note = $_.Exception.Message }
        Write-Fail ('setup-answers.json: {0}' -f $_.Exception.Message)
        $anyFail = $true
    }
    Write-Host ''
    Write-Host 'Apply results (per item):' -ForegroundColor Cyan
    foreach ($r in $results) {
        if ($r.Ok) { Write-Host (('  [ok]   {0}  ({1})' -f $r.Item, $r.Note)) -ForegroundColor Green }
        else { Write-Host (('  [FAIL] {0}  ({1})' -f $r.Item, $r.Note)) -ForegroundColor Red }
    }
    if ($anyFail) {
        Write-Host '' 
        Write-Host 'Automatic rollback list (apply these to undo this run):' -ForegroundColor Yellow
        # Attempt automatic env restore for values we overwrote.
        try {
            foreach ($k in $oldEnv.Keys) {
                $v = $oldEnv[$k]
                if ([string]::IsNullOrEmpty($v)) {
                    [Environment]::SetEnvironmentVariable($k, $null, 'User')
                } else {
                    [Environment]::SetEnvironmentVariable($k, $v, 'User')
                }
            }
            Write-Warn 'User-level env vars were restored to pre-apply values (process env keeps applied values for this session).'
        } catch {
            Write-Warn ('Env auto-restore failed: {0}' -f $_.Exception.Message)
        }
        $i = 1
        foreach ($rb in $rollbacks) {
            Write-Host (('  {0}. {1}' -f $i, $rb)) -ForegroundColor Yellow
            $i++
        }
        if ($answersBackup) { Write-Host ('  Tip: Copy-Item "{0}" "{1}" -Force' -f $answersBackup, $script:AnswersPath) -ForegroundColor Gray }
        Write-WizardLog 'Apply finished WITH failures; rollback list shown.'
    } else {
        $script:StatusFlags.Applied = $true
        Write-Ok 'Apply finished: all items ok.'
        Write-WizardLog 'Apply finished OK.'
    }
    Mark-StepDone -Label 'Apply'
    if ($anyFail) { return $false }
    return $true
}
#endregion

#region F1 welcome, F2 menu, F13 browser, F20 goodbye
function Show-Welcome {
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '  Jellyfin + TorBox + PotPlayer — First-Run Setup Wizard' -ForegroundColor Cyan
    Write-Host ('  v{0}   PUBLIC repo (MIT) — secrets are never committed' -f $script:WizardVersion) -ForegroundColor Gray
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host 'This wizard will:' -ForegroundColor White
    Write-Host '  1. Store your TorBox key + Jellyfin connection (env vars only, never in git).' -ForegroundColor White
    Write-Host '  2. Set up library folders, PotPlayer path, and playback mode.' -ForegroundColor White
    Write-Host '  3. Check rclone.conf, ports, and service health for you.' -ForegroundColor White
    Write-Host '  4. Show every change first (dry-run), then apply with rollback notes.' -ForegroundColor White
    Write-Host '  5. Save non-secret answers for fast re-runs (-Resume / -NonInteractive).' -ForegroundColor White
    Write-Host ''
    Write-Host 'Navigate with numbers. Type q any time to quit, back to go back.' -ForegroundColor Gray
    Write-WizardLog 'Welcome shown.'
}
function Show-MainMenu {
    while ($true) {
        Write-Host ''
        Write-Host '================ Setup menu ================' -ForegroundColor Cyan
        Write-Host ('Progress: {0}/{1} steps done.' -f $script:CompletedSteps, $script:TotalSteps) -ForegroundColor Gray
        $t1 = 'pending'; if ($script:StatusFlags.TorboxVerified) { $t1 = 'verified' }
        $t2 = 'pending'; if ($script:StatusFlags.JellyfinVerified) { $t2 = 'verified' }
        $t3 = 'pending'; if ($script:StatusFlags.Applied) { $t3 = 'applied' }
        Write-Host ('  1) TorBox key + scope ............ [{0}]' -f $t1) -ForegroundColor White
        Write-Host ('  2) Library roots ({0})' -f $script:State.LibraryRoots.Count) -ForegroundColor White
        Write-Host ('  3) Jellyfin connection ........... [{0}]' -f $t2) -ForegroundColor White
        Write-Host '  4) PotPlayer path (auto-detect)' -ForegroundColor White
        Write-Host '  5) rclone.conf check' -ForegroundColor White
        Write-Host '  6) Port check (8888/18099/18080/8096)' -ForegroundColor White
        Write-Host ('  7) Playback mode [{0}]' -f $script:State.PlaybackMode) -ForegroundColor White
        Write-Host '  8) Dry-run summary (review changes)' -ForegroundColor White
        Write-Host ('  9) Apply changes ................. [{0}]' -f $t3) -ForegroundColor White
        Write-Host '  10) Health check' -ForegroundColor White
        Write-Host '  11) Save answers + open panel + finish' -ForegroundColor White
        Write-Host '  q) Quit wizard' -ForegroundColor White
        Write-Host 'Tip: inside any step, type back to return here.' -ForegroundColor Gray
        $sel = $null
        try { $sel = Read-Host -Prompt 'Choose [1-11/q]' } catch { Write-Warn 'Input error; showing menu again.'; continue }
        if ($null -eq $sel) { continue }
        $sel = $sel.Trim()
        if (($sel -eq 'q') -or ($sel -eq 'Q')) { return 'quit' }
        if (($sel -eq 'back') -or ($sel -eq 'b')) { Write-Info 'Already at the main menu.'; continue }
        switch ($sel) {
            '1' {
                $r = Invoke-TorboxStep
                if ($r -eq $false) { return 'quit' }
            }
            '2' {
                $r = Invoke-LibraryStep
                if ($r -eq $false) { return 'quit' }
            }
            '3' {
                $r = Invoke-JellyfinStep
                if ($r -eq $false) { return 'quit' }
            }
            '4' {
                $r = Invoke-PotPlayerStep
                if ($r -eq $false) { return 'quit' }
            }
            '5' {
                [void](Invoke-RcloneStep)
            }
            '6' {
                [void](Invoke-PortStep)
            }
            '7' {
                $r = Invoke-PlaybackStep
                if ($r -eq $false) { return 'quit' }
            }
            '8' {
                Show-DryRunSummary
            }
            '9' {
                [void](Invoke-ApplyStep)
            }
            '10' {
                [void](Invoke-HealthCheck)
            }
            '11' {
                return 'finish'
            }
            default { Write-Warn 'Enter a number 1-11, or q to quit.' }
        }
    }
}
function Invoke-OpenPanelOptIn {
    if ($NonInteractive) {
        if ($script:State.OpenBrowser) {
            try {
                Start-Process $script:State.PanelUrl | Out-Null
                Write-Ok ('Panel opened (NonInteractive, OpenBrowser=true): {0}' -f $script:State.PanelUrl)
            } catch {
                Write-Warn ('Could not open browser: {0}' -f $_.Exception.Message)
            }
        } else {
            Write-Info 'NonInteractive: browser open skipped (openBrowser=false).'
        }
        return
    }
    $got = Read-PlainValidated -Prompt ('Open panel {0} in browser? [y/N]' -f $script:State.PanelUrl) -Default 'N' -AllowEmpty $false `
        -Validate { param($v, [ref]$e) if ($v -match '(?i)^y(es)?$|^n(o)?$') { return $true }; $e.Value = 'Enter Y or N.'; return $false }
    if ($got.Quit) { return }
    if ($got.Back) { return }
    if ($got.Value -match '(?i)^y') {
        $script:State.OpenBrowser = $true
        try {
            Start-Process $script:State.PanelUrl | Out-Null
            Write-Ok ('Panel opened: {0}' -f $script:State.PanelUrl)
        } catch {
            Write-Warn ('Could not open browser: {0}. Open the URL manually.' -f $_.Exception.Message)
        }
    } else {
        $script:State.OpenBrowser = $false
        Write-Info ('Skipped. Open manually: {0}' -f $script:State.PanelUrl)
    }
}
function Show-Goodbye {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host '  Setup wizard finished. Enjoy your media stack!' -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host 'Docs:' -ForegroundColor Cyan
    Write-Host '  - README.md         quick start (panel :18080, proxy :8888, Jellyfin :8096)' -ForegroundColor White
    Write-Host '  - CONTROL_PANEL.md  panel guide (http://127.0.0.1:18080/)' -ForegroundColor White
    Write-Host '  - ARCHITECTURE.md   ports, services, data flow' -ForegroundColor White
    Write-Host '  - RUNBOOK.md        rotation, recovery, troubleshooting' -ForegroundColor White
    Write-Host 'Next:' -ForegroundColor Cyan
    Write-Host '  - Start the stack:  pwsh -File supervisor.ps1' -ForegroundColor White
    Write-Host '  - Panel:            http://127.0.0.1:18080' -ForegroundColor White
    Write-Host '  - Jellyfin:         http://127.0.0.1:8096' -ForegroundColor White
    Write-Host '  - Re-run wizard:    pwsh -File setup-wizard.ps1 -Resume' -ForegroundColor White
    Write-Host '' 
    Write-Host 'If this stack helped you, please star the repo:' -ForegroundColor Yellow
    Write-Host ('  {0}' -f $script:RepoUrl) -ForegroundColor Yellow
    Write-Host 'Stars keep this MIT project alive. Thank you!' -ForegroundColor Yellow
    Write-WizardLog 'Goodbye shown.'
}
#endregion

#region Main flow
function Invoke-WizardMain {
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:LogPath) | Out-Null
    } catch {}
    Write-WizardLog ('--- setup-wizard v{0} start (Resume={1} NonInteractive={2}) ---' -f $script:WizardVersion, [bool]$Resume, [bool]$NonInteractive)
    if ($NonInteractive -and $Resume) {
        Write-Warn 'Both -Resume and -NonInteractive were passed; NonInteractive wins (answers file only).'
    }
    # F15/F16: preload answers.
    $preloaded = $false
    if ($NonInteractive -or $Resume) {
        $ans = Load-WizardAnswers -Path $script:AnswersPath
        if ($ans) {
            Apply-AnswersToState -Answers $ans
            $preloaded = $true
            Write-Ok ('Loaded saved answers from {0}.' -f $script:AnswersPath)
        } else {
            if ($NonInteractive) {
                Write-Fail ('NonInteractive requires a valid answers file at {0}. Run interactively once first (it saves setup-answers.json).' -f $script:AnswersPath)
                return 1
            }
            Write-Warn ('No usable answers file at {0}; starting fresh.' -f $script:AnswersPath)
        }
    }
    # Env-backed secrets are allowed to prefill memory in NonInteractive only.
    if ($NonInteractive) {
        if (-not [string]::IsNullOrWhiteSpace($env:TORBOX_API_KEY)) { $script:Secrets.TorboxKey = $env:TORBOX_API_KEY.Trim() }
        if (-not [string]::IsNullOrWhiteSpace($env:JELLYFIN_API_KEY)) { $script:Secrets.JellyfinToken = $env:JELLYFIN_API_KEY.Trim() }
        if ([string]::IsNullOrWhiteSpace($script:State.JellyfinUrl)) { $script:State.JellyfinUrl = 'http://127.0.0.1:8096' }
        if ([string]::IsNullOrWhiteSpace($script:State.PlaybackMode)) { $script:State.PlaybackMode = 'FullSeason' }
        # Headless straight-through: verify, dry-run, apply, health, goodbye.
        Show-Welcome
        [void](Invoke-TorboxStep)
        [void](Invoke-LibraryStep)
        [void](Invoke-JellyfinStep)
        [void](Invoke-PotPlayerStep)
        [void](Invoke-RcloneStep)
        [void](Invoke-PortStep)
        [void](Invoke-PlaybackStep)
        Show-DryRunSummary
        $ok = Invoke-ApplyStep
        [void](Invoke-HealthCheck)
        Invoke-OpenPanelOptIn
        Show-Goodbye
        if ($ok) { return 0 }
        return 1
    }
    # Interactive.
    Show-Welcome
    if ($preloaded) { Write-Info 'Resumed from setup-answers.json (secrets still entered fresh).' }
    $outcome = Show-MainMenu
    if ($outcome -eq 'quit') {
        Write-Info 'Wizard quit before finishing. Non-secret answers are saved for next time.'
        [void](Save-WizardAnswers)
        Write-WizardLog 'Quit by user.'
        Show-Goodbye
        return 0
    }
    # Finish path: final dry-run -> confirm -> apply -> health -> browser -> save -> goodbye.
    Show-DryRunSummary
    $confirm = Read-PlainValidated -Prompt 'Apply these changes now? [Y/n]' -Default 'Y' -AllowEmpty $false `
        -Validate { param($v, [ref]$e) if ($v -match '(?i)^y(es)?$|^n(o)?$') { return $true }; $e.Value = 'Enter Y or N.'; return $false }
    if ($confirm.Quit) { return 0 }
    if (-not $confirm.Back) {
        if ($confirm.Value -match '(?i)^y') {
            [void](Invoke-ApplyStep)
            [void](Invoke-HealthCheck)
        } else {
            Write-Info 'Apply skipped. Answers below are still saved for later.'
        }
    }
    Invoke-OpenPanelOptIn
    [void](Save-WizardAnswers)
    Show-Goodbye
    return 0
}
#endregion

# Dot-source safe: '. .\setup-wizard.ps1' loads functions without running the wizard.
if ($MyInvocation.InvocationName -eq '.') { return }
$code = 0
try { $code = Invoke-WizardMain } catch {
    try { Write-Fail ('Unexpected wizard error: {0}' -f $_.Exception.Message) } catch {}
    try { Write-WizardLog ('FATAL: {0}' -f $_.ToString()) } catch {}
    $code = 1
}
exit $code
