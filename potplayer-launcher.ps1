param(
    [switch]$FullSeason,
    [switch]$Single,
    [switch]$WhatIf,
    [Parameter(Position=0, ValueFromRemainingArguments=$true)]
    [string[]]$rawArgs
)
# Force-foreground helper: restores the PotPlayer window if it opens behind
# everything (foreground-lock) or starts minimized to tray with no taskbar button.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PotFgFix {
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
}
'@ -ErrorAction SilentlyContinue
$script:PotFgTried = $false
function Restore-PotPlayerForeground {
    # Best-effort only: never throws, never blocks launch.
    try {
        if ($script:PotFgTried) { return }
        $script:PotFgTried = $true
        Start-Sleep -Milliseconds 1500
        $p = Get-Process -Name 'PotPlayerMini64','PotPlayer64','PotPlayer' -ErrorAction SilentlyContinue |
             Sort-Object StartTime -Descending | Select-Object -First 1
        if (-not $p) { Write-BridgeLog 'FOREGROUND: no PotPlayer process found after launch.'; return }
        $h = [IntPtr]$p.MainWindowHandle
        $tries = 0
        while (($h -eq [IntPtr]::Zero) -and ($tries -lt 10)) {
            Start-Sleep -Milliseconds 500
            try { $p.Refresh() } catch {}
            $h = [IntPtr]$p.MainWindowHandle
            $tries++
        }
        if ($h -eq [IntPtr]::Zero) {
            # Tray-minimize guard: visible process but no window handle = check tray.
            Write-BridgeLog 'FOREGROUND: PotPlayer running with no window handle (likely tray-minimized). Disable tray-minimize in PotPlayer Preferences > General.';
            return
        }
        if ([PotFgFix]::IsIconic($h)) { [void][PotFgFix]::ShowWindowAsync($h, 9) }  # SW_RESTORE
        [void][PotFgFix]::ShowWindowAsync($h, 5)  # SW_SHOW
        [void][PotFgFix]::SetForegroundWindow($h)
        Write-BridgeLog 'FOREGROUND: PotPlayer window restored to foreground.'
    } catch { Write-BridgeLog ("FOREGROUND: helper failed: " + $_.Exception.Message) }
}
function Start-PotPlayer {
  # Single choke point for all 12 launch sites: launch, then best-effort foreground restore.
  param([string]$FilePath, $ArgumentList, [string]$WindowStyle = 'Normal')
  Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WindowStyle $WindowStyle | Out-Null
  Restore-PotPlayerForeground
}
# DEFAULT: full-season playlist (whole series folder visible in PotPlayer, as before).
# Opt-out to instant single + lazy next via -Single switch or env POTPLAYER_SINGLE=1.
# -FullSeason switch / POTPLAYER_FULL_SEASON=1 kept for compat (both mean full season).
try {
    [bool]$wantSingle = [bool]$Single
    if ($rawArgs -contains '-Single' -or $rawArgs -contains '/Single' -or $rawArgs -contains '--Single') { $wantSingle = $true }
    if ($env:POTPLAYER_SINGLE -eq '1') { $wantSingle = $true }
    if ($wantSingle) {
        $FullSeason = $false
        $rawArgs = @($rawArgs | Where-Object { $_ -ne '-Single' -and $_ -ne '/Single' -and $_ -ne '--Single' })
    } else {
        $FullSeason = $true
    }
    if ($FullSeason) { $rawArgs = @($rawArgs | Where-Object { $_ -ne '-FullSeason' -and $_ -ne '/FullSeason' -and $_ -ne '--FullSeason' }) }
    if ($WhatIf -or ($rawArgs -contains '-WhatIf')) {
        $WhatIf = $true
        $rawArgs = @($rawArgs | Where-Object { $_ -ne '-WhatIf' -and $_ -ne '/WhatIf' -and $_ -ne '--WhatIf' })
    }
} catch {}
$script:FullSeasonMode = [bool]$FullSeason
function Get-TorboxApiKey { if ($env:TORBOX_API_KEY) { return $env:TORBOX_API_KEY }; Write-Warning "TORBOX_API_KEY env var not set"; return "" }
# Single health-probe cache: exactly one 127.0.0.1:8888/health probe per launch, reused everywhere.
$script:ProxyHealthCached = $null
$script:ProxyHealthTimestamp = [DateTime]::MinValue
function Test-ProxyHealthCached {
    param([switch]$Force)
    if ((-not $Force) -and ($null -ne $script:ProxyHealthCached)) {
        try {
            if (([DateTime]::UtcNow - $script:ProxyHealthTimestamp.ToUniversalTime()).TotalSeconds -lt 60) {
                return [bool]$script:ProxyHealthCached
            }
        } catch {}
    }
    try {
        Invoke-RestMethod -Uri 'http://127.0.0.1:8888/health' -TimeoutSec 2 -ErrorAction Stop | Out-Null
        $script:ProxyHealthCached = $true
    } catch { $script:ProxyHealthCached = $false }
    $script:ProxyHealthTimestamp = [DateTime]::UtcNow
    return [bool]$script:ProxyHealthCached
}

# Natural-sort key: pads digit runs so lexical compare equals numeric (E2 < E10).
function Get-NaturalSortKey([string]$Name) {
    if ([string]::IsNullOrEmpty($Name)) { return $Name }
    try {
        return [regex]::Replace($Name, '\d+', { param($m) $m.Value.PadLeft(10, '0') })
    } catch { return $Name }
}

# Combine any split arguments if Windows passes unquoted spaces
$inputUri = ($rawArgs -join ' ').Trim()
# Dot-source safe: parser verification (. F:\Jellyfin\potplayer-launcher.ps1) must not exit host or launch playback.
if (-not $inputUri) { if ($MyInvocation.InvocationName -eq '.') { return } else { exit } }

try {
    $logDir = 'F:\Jellyfin\logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logLine = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] RAW: $inputUri"
    Add-Content -Path (Join-Path $logDir 'potplayer-launcher.log') -Value $logLine -ErrorAction SilentlyContinue
    $script:LaunchStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    # UX: Show realtime log window immediately after click (so Adolescence 15s wait has feedback, not just PotPlayer Opening...)
    try{
        $viewer = "F:\Jellyfin\show-playback-log.ps1"
        if(Test-Path -LiteralPath $viewer){
            Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile","-WindowStyle","Normal","-ExecutionPolicy","Bypass","-File","`"$viewer`"" -WindowStyle Normal -ErrorAction SilentlyContinue | Out-Null
            Add-Content -Path (Join-Path $logDir 'potplayer-launcher.log') -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] UX: Log window launched" -ErrorAction SilentlyContinue
        }
    } catch {}
} catch {}

# 1. Clean protocol prefix
$target = $inputUri -replace '^potplayer://', '' -replace '^"potplayer://', '' -replace '^''potplayer://', ''
$target = $target.Trim().Trim('"').Trim("'").TrimEnd('\').TrimEnd('/')

# 2. Decode payload (Base64 lossless or URL decode fallback)
if ($target.StartsWith('b64:')) {
    try {
        $b64Data = $target.Substring(4)
        $bytes = [System.Convert]::FromBase64String($b64Data)
        $target = [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch {
        $target = [System.Uri]::UnescapeDataString($target)
    }
} else {
    $target = [System.Uri]::UnescapeDataString($target)
}
$target = $target.Trim().Trim('"').Trim("'").TrimEnd('\').TrimEnd('/')

# 3. Parse optional metadata query parameters (target|itemId|userId|token|serverUrl)
$mediaPath = $target
$itemId = ""
$userId = ""
$token = ""
$serverUrl = "http://localhost:8096"

if ($target.Contains('|')) {
    $parts = $target.Split('|')
    $mediaPath = $parts[0]
    if ($parts.Length -gt 1) { $itemId = $parts[1] }
    if ($parts.Length -gt 2) { $userId = $parts[2] }
    if ($parts.Length -gt 3) { $token = $parts[3] }
    if ($parts.Length -gt 4) { $serverUrl = $parts[4] }
}

# Resolve item:<jellyfin-id> payloads inside the launcher so the browser does not
# need to wait for API calls before invoking the custom protocol.
if ($mediaPath -match '^item:(.+)$') {
    $requestedId = $Matches[1]
    # Normalize undashed 32-char GUID to dashed (as Jellyfin API needs dashed) + fix Desperate 31-char 503367c vs DB 5033367c
    if ($requestedId -match '^[0-9a-fA-F]{32}$') {
        $requestedId = $requestedId -replace '^(.{8})(.{4})(.{4})(.{4})(.{12})$','$1-$2-$3-$4-$5'
        $requestedId = $requestedId.ToLowerInvariant()
    } elseif ($requestedId -match '^[0-9a-fA-F]{31}$') {
        $fixed = $requestedId -replace "503367c","5033367c"
        if ($fixed -match '^[0-9a-fA-F]{32}$') {
            $requestedId = $fixed -replace '^(.{8})(.{4})(.{4})(.{4})(.{12})$','$1-$2-$3-$4-$5'
            $requestedId = $requestedId.ToLowerInvariant()
        } else {
            $requestedId = $requestedId -replace '^(.{8})(.{4})(.{4})(.{4})(.{11})$','$1-$2-$3-$4-0$5'
            $requestedId = $requestedId.ToLowerInvariant()
        }
    }
    try {
        if (-not $userId -or -not $token) { throw 'Jellyfin credentials missing' }
        $headers = @{ 'X-Emby-Token' = $token }
        $itemUrl = $serverUrl.TrimEnd('/') + '/Users/' + $userId + '/Items/' + $requestedId
        $resolvedItem = Invoke-RestMethod -Uri $itemUrl -Headers $headers -TimeoutSec 8 -ErrorAction Stop
        if ($resolvedItem.Type -eq 'Episode' -and $resolvedItem.Path) {
            $mediaPath = $resolvedItem.Path
            $itemId = $resolvedItem.Id
        } elseif ($resolvedItem.Type -eq 'Series') {
            $sid = $resolvedItem.Id
            if ($sid -match '^[0-9a-fA-F]{32}$') { $sid = $sid -replace '^(.{8})(.{4})(.{4})(.{4})(.{12})$','$1-$2-$3-$4-$5'; $sid = $sid.ToLowerInvariant() }
            elseif ($sid -match '^[0-9a-fA-F]{31}$') { $f=$sid -replace "503367c","5033367c"; if($f -match '^[0-9a-fA-F]{32}$'){ $sid=$f -replace '^(.{8})(.{4})(.{4})(.{4})(.{12})$','$1-$2-$3-$4-$5'; $sid=$sid.ToLowerInvariant() } else { $sid=$sid -replace '^(.{8})(.{4})(.{4})(.{4})(.{11})$','$1-$2-$3-$4-0$5'; $sid=$sid.ToLowerInvariant() } }
            $episodesUrl = $serverUrl.TrimEnd('/') + '/Shows/' + $sid + '/Episodes?UserId=' + $userId + '&Limit=1&Fields=Path'
            $episodeResult = Invoke-RestMethod -Uri $episodesUrl -Headers $headers -TimeoutSec 8 -ErrorAction Stop
            if ($episodeResult.Items.Count -gt 0) {
                $mediaPath = $episodeResult.Items[0].Path
                $itemId = $episodeResult.Items[0].Id
            }
        } elseif ($resolvedItem.Type -eq 'Season') {
            $sid2 = $resolvedItem.SeriesId
            $id2 = $resolvedItem.Id
            if ($sid2 -match '^[0-9a-fA-F]{32}$') { $sid2 = $sid2 -replace '^(.{8})(.{4})(.{4})(.{4})(.{12})$','$1-$2-$3-$4-$5'; $sid2 = $sid2.ToLowerInvariant() }
            elseif ($sid2 -match '^[0-9a-fA-F]{31}$') { $f=$sid2 -replace "503367c","5033367c"; if($f -match '^[0-9a-fA-F]{32}$'){ $sid2=$f -replace '^(.{8})(.{4})(.{4})(.{4})(.{12})$','$1-$2-$3-$4-$5'; $sid2=$sid2.ToLowerInvariant() } else { $sid2=$sid2 -replace '^(.{8})(.{4})(.{4})(.{4})(.{11})$','$1-$2-$3-$4-0$5'; $sid2=$sid2.ToLowerInvariant() } }
            if ($id2 -match '^[0-9a-fA-F]{32}$') { $id2 = $id2 -replace '^(.{8})(.{4})(.{4})(.{4})(.{12})$','$1-$2-$3-$4-$5'; $id2 = $id2.ToLowerInvariant() }
            elseif ($id2 -match '^[0-9a-fA-F]{31}$') { $f=$id2 -replace "503367c","5033367c"; if($f -match '^[0-9a-fA-F]{32}$'){ $id2=$f -replace '^(.{8})(.{4})(.{4})(.{4})(.{12})$','$1-$2-$3-$4-$5'; $id2=$id2.ToLowerInvariant() } else { $id2=$id2 -replace '^(.{8})(.{4})(.{4})(.{4})(.{11})$','$1-$2-$3-$4-0$5'; $id2=$id2.ToLowerInvariant() } }
            $episodesUrl = $serverUrl.TrimEnd('/') + '/Shows/' + $sid2 + '/Episodes?SeasonId=' + $id2 + '&UserId=' + $userId + '&Limit=1&Fields=Path'
            $episodeResult = Invoke-RestMethod -Uri $episodesUrl -Headers $headers -TimeoutSec 8 -ErrorAction Stop
            if ($episodeResult.Items.Count -gt 0) {
                $mediaPath = $episodeResult.Items[0].Path
                $itemId = $episodeResult.Items[0].Id
            }
        }
    } catch {
        $mediaPath = ''
    }
}

        if ($mediaPath -and $mediaPath.StartsWith('R:\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $mediaPath = 'F:\Media\' + $mediaPath.Substring(3)
        } elseif ($mediaPath -and $mediaPath.StartsWith('R:/', [System.StringComparison]::OrdinalIgnoreCase)) {
            $mediaPath = 'F:/Media/' + $mediaPath.Substring(3)
        }
        
        # 5. Normalize path slashes for Windows
        if ($mediaPath -and $mediaPath -match '^[a-zA-Z]:') {
            $mediaPath = $mediaPath -replace '/', '\'
        }

# 5b. Resolve .strm indirection (Jellyfin sends F:\TorboxMedia\...\*.strm containing T:\... path)
# GLOBAL FIX: Audit + resilient handling for stale Torbox VFS cache (500h -> 30s)
# Previous bug: condition "(Test-Path OR extension-match)" treated non-existent T:\*.mkv as valid,
# causing PotPlayer "File not found" dialog. This edgecase occurs when rclone dir-cache is stale:
# remote (torbox:9-1-1.S09...) exists but T:\ folder not visible until vfs/refresh.
function Write-BridgeLog([string]$m){ try{ Add-Content -Path (Join-Path 'F:\Jellyfin\logs' 'potplayer-launcher.log') -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $m" -ErrorAction SilentlyContinue }catch{} }
function Test-PlaylistMediaFileName([string]$name){
    if([string]::IsNullOrWhiteSpace($name)){ return $false }
    $sidecarExtensions = @('.txt','.nfo','.jpg','.jpeg','.png','.gif','.srt','.ass','.ssa','.sub','.idx','.sup','.sfv','.md5','.url','.torrent')
    return ($sidecarExtensions -notcontains ([System.IO.Path]::GetExtension($name).ToLowerInvariant()))
}
function Test-TorboxRemoteExists([string]$tPath){
    try{
        if($tPath -notmatch '^[Tt]:\\') { return $null }
        $rel = $tPath.Substring(3) -replace '\\','/'
        $firstSlash = $rel.IndexOf('/')
        $torboxPath = if($firstSlash -ge 0){ $rel.Substring(0,$firstSlash) } else { $rel }
        $rcloneExe = 'F:\Jellyfin\server\rclone.exe'; if(-not (Test-Path $rcloneExe)){ $rcloneExe = 'rclone' }
        $conf = 'F:\Jellyfin\config\rclone.conf'
        $out = & $rcloneExe --config "$conf" lsjson "torbox:$torboxPath" --max-depth 1 2>$null | Out-String
        if($out -match [regex]::Escape($torboxPath.Split('/')[0])){ return $true }
        # Fallback: check full dir listing contains file
        $dirPart = Split-Path $rel -Parent; if(-not $dirPart){ $dirPart = $torboxPath }
        $out2 = & $rcloneExe --config "$conf" lsjson "torbox:$dirPart" 2>$null | Out-String
        return ($out2 -match [regex]::Escape((Split-Path $rel -Leaf)))
    }catch{ return $null }
}
function Invoke-TorboxVfsRefresh([string]$tPath){
    try{
        # Try rclone RC if available (requires --rc on mount; new mount_torbox.vbs now enables it)
        try{ Invoke-RestMethod -Uri 'http://127.0.0.1:5572/vfs/refresh' -Method POST -Body (@{dir=(Split-Path $tPath -Parent)}|ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 3 -ErrorAction SilentlyContinue | Out-Null; return $true }catch{}
        # Fallback: force remote poll by running a lightweight lsjson (bypasses VFS cache)
        $rcloneExe = 'F:\Jellyfin\server\rclone.exe'; if(-not (Test-Path $rcloneExe)){ $rcloneExe='rclone' }
        & $rcloneExe --config 'F:\Jellyfin\config\rclone.conf' lsf "torbox:" 2>$null | Out-Null
        Start-Sleep -Milliseconds 800
        return $true
    }catch{ return $false }
}
# NEW GLOBAL FIX 2026-08-24b: Full-cache fallback — ensures PotPlayer gets a link it can download fully (VFS sparse vs HTTP progressive)
# Previous Jellyfin stream fallback (/Videos/{id}/stream) returned 93-byte .strm content (Content-Length 93) not video, so PotPlayer wouldn't cache full file.
# This helper tries (in order): 1) rclone copy to local prefetch (guaranteed full file on disk), 2) Torbox direct CDN URL via API (range-capable, cacheable), 3) null
function Get-TorboxDirectLinkViaApi([string]$tPath){
    try{
        if($tPath -notmatch '^[Tt]:\\') { return $null }
        $rel = $tPath.Substring(3) -replace '\\','/'
        $fileName = Split-Path $rel -Leaf
        $apiKey = Get-TorboxApiKey
        $headers = @{ Authorization="Bearer $apiKey" }
        $listUrl = "https://api.torbox.app/v1/api/torrents/mylist?bypass_cache=true"
        $resp = Invoke-RestMethod -Uri $listUrl -Headers $headers -TimeoutSec 12 -ErrorAction SilentlyContinue
        if(-not $resp.success -or -not $resp.data){ Write-BridgeLog "Torbox mylist empty: $($resp | ConvertTo-Json -Compress)"; return $null }
        # GLOBAL: match by file short_name across ALL torrents (torrent.name is often localized e.g. "911 служба спасения" vs WebDAV folder "9-1-1.S09...", so do NOT filter by folder)
        foreach($tor in $resp.data){
            if(-not $tor.files){ continue }
            foreach($f in $tor.files){
                $shortName = [string]$f.short_name
                $apiName = [string]$f.name
                $nameMatches = [string]::Equals($shortName, $fileName, [System.StringComparison]::OrdinalIgnoreCase)
                if(-not $nameMatches -and $apiName){
                    $nameMatches = $apiName.IndexOf($fileName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                }
                if(-not $nameMatches){ continue }
                $fileId = $f.id; $torrentId = $tor.id
                $safeTorName = if($tor.name.Length -gt 60){ $tor.name.Substring(0,60) } else { $tor.name }
                Write-BridgeLog "Torbox match: $fileName -> torrent $torrentId ($safeTorName) file $fileId"
                $proxyUrl = "http://127.0.0.1:8888/torbox/$torrentId/$fileId/$([Uri]::EscapeDataString($fileName))"
                if (Test-ProxyHealthCached) {
                    Write-BridgeLog "Torbox proxy URL for $fileName (torrent $torrentId file $fileId): $proxyUrl (deferred CDN resolution)"
                    return $proxyUrl
                }
                $dlUrl = "https://api.torbox.app/v1/api/torrents/requestdl?token=$apiKey&torrent_id=$torrentId&file_id=$fileId&zip=false"
                try{
                    $dlResp = Invoke-RestMethod -Uri $dlUrl -Headers $headers -TimeoutSec 12 -ErrorAction SilentlyContinue
                    if($dlResp.success -and $dlResp.data){
                        $cdnPreview = [string]$dlResp.data; if($cdnPreview.Length -gt 80){ $cdnPreview = $cdnPreview.Substring(0,80) }
                        # Return proxy URL (never expires) instead of direct CDN (expires) — proxy will 302 to fresh CDN on each PotPlayer request
                        $proxyUrl = "http://127.0.0.1:8888/torbox/$torrentId/$fileId/$([Uri]::EscapeDataString($fileName))"
                        Write-BridgeLog "Torbox proxy URL for $fileName (torrent $torrentId file $fileId): $proxyUrl (direct $cdnPreview...)"
                        # Single cached probe per launch (do NOT probe per-file in loop)
                        if (Test-ProxyHealthCached) {
                            return $proxyUrl
                        } else {
                            Write-BridgeLog "Proxy not running, using direct CDN"
                            return [string]$dlResp.data
                        }
                    }
                    else{ Write-BridgeLog "Torbox requestdl failed for $torrentId/$fileId : $($dlResp.detail)" }
                }catch{ Write-BridgeLog "Torbox requestdl exception $torrentId/$fileId : $_" }
            }
        }
        Write-BridgeLog "Torbox direct link: no match for $fileName in $($resp.data.Count) torrents"
    }catch{ Write-BridgeLog "Get-TorboxDirectLinkViaApi error: $_" }
    return $null
}
# --- BULK CDN RESOLVER + CACHE (fixes full 23-ep playlist, not 3-shortcut) ---
$script:torboxMylistCache=$null; $script:torboxMylistCacheTime=0; $script:torboxLinkCache=@{}; $script:torboxMylistSourceLogged=$false
function Get-TorboxMylistCached{
    try{
        $now=[DateTimeOffset]::Now.ToUnixTimeSeconds()
        if($script:torboxMylistCache -and ($now - $script:torboxMylistCacheTime) -lt 60){ return $script:torboxMylistCache }
        # Proxy-shared mylist FIRST (saves TorBox API quota): use only when fresh (age_s < 900), else direct fallback.
        try{
            $proxyResp=Invoke-RestMethod -Uri "http://127.0.0.1:8888/mylist" -TimeoutSec 8 -ErrorAction Stop
            $proxyData=$null; $proxyAge=[int]::MaxValue
            if($proxyResp -is [System.Array]){ $proxyData=$proxyResp; $proxyAge=0 }
            elseif($null -ne $proxyResp){
                if($proxyResp.PSObject.Properties['age_s']){ try{ $proxyAge=[int]$proxyResp.age_s }catch{} }
                elseif($proxyResp.PSObject.Properties['age']){ try{ $proxyAge=[int]$proxyResp.age }catch{} }
                if($proxyResp.PSObject.Properties['data'] -and $proxyResp.data){ $proxyData=$proxyResp.data }
                elseif($proxyResp.PSObject.Properties['torrents'] -and $proxyResp.torrents){ $proxyData=$proxyResp.torrents }
            }
            if($proxyData -and $proxyAge -lt 900){
                $script:torboxMylistCache=$proxyData; $script:torboxMylistCacheTime=$now
                if(-not $script:torboxMylistSourceLogged){ $script:torboxMylistSourceLogged=$true; Write-BridgeLog "Torbox mylist source=proxy-shared age_s=$proxyAge count=$($proxyData.Count)" }
                return $proxyData
            }
        }catch{}
        $apiKey=Get-TorboxApiKey; $headers=@{ Authorization="Bearer $apiKey" }
        $resp=Invoke-RestMethod -Uri "https://api.torbox.app/v1/api/torrents/mylist?bypass_cache=true" -Headers $headers -TimeoutSec 12 -ErrorAction SilentlyContinue
        if($resp.success -and $resp.data){
            $script:torboxMylistCache=$resp.data; $script:torboxMylistCacheTime=$now
            if(-not $script:torboxMylistSourceLogged){ $script:torboxMylistSourceLogged=$true; Write-BridgeLog "Torbox mylist source=direct count=$($resp.data.Count)" }
            return $resp.data
        }
    }catch{ Write-BridgeLog "Get-TorboxMylistCached error: $_" }
    return $script:torboxMylistCache
}
function Get-TorboxBulkLinks([string[]]$fileNames){
    $map=@{}
    try{
        $data=Get-TorboxMylistCached
        if(-not $data){ return $map }
        $apiKey=Get-TorboxApiKey; $headers=@{ Authorization="Bearer $apiKey" }
        # Build filename -> torrent/fileId lookup from cached mylist (one fetch)
        $lookup=@{}
        foreach($tor in $data){
            if(-not $tor.files){ continue }
            foreach($f in $tor.files){
                $k=$f.short_name
                if(-not $lookup.ContainsKey($k)){ $lookup[$k]=@{ torrentId=$tor.id; fileId=$f.id } }
            }
        }
        # Single cached health probe for the whole batch (not per-file in loop).
        $proxyUp = Test-ProxyHealthCached
        foreach($fn in $fileNames){
            if($script:torboxLinkCache.ContainsKey($fn)){ $map[$fn]=$script:torboxLinkCache[$fn]; continue }
            if($lookup.ContainsKey($fn)){
                $m=$lookup[$fn]
                $proxyUrl="http://127.0.0.1:8888/torbox/$($m.torrentId)/$($m.fileId)/$([Uri]::EscapeDataString($fn))"
                if($proxyUp){
                    $map[$fn]=$proxyUrl; $script:torboxLinkCache[$fn]=$proxyUrl
                    Write-BridgeLog "Bulk proxy deferred CDN: $fn -> $proxyUrl"
                    continue
                }
                try{
                    $dlUrl="https://api.torbox.app/v1/api/torrents/requestdl?token=$apiKey&torrent_id=$($m.torrentId)&file_id=$($m.fileId)&zip=false"
                    $dlResp=Invoke-RestMethod -Uri $dlUrl -Headers $headers -TimeoutSec 10 -ErrorAction SilentlyContinue
                    if($dlResp.success -and $dlResp.data){
                        $cdn=[string]$dlResp.data; $proxyUrl="http://127.0.0.1:8888/torbox/$($m.torrentId)/$($m.fileId)/$([Uri]::EscapeDataString($fn))"
                        # Return proxy (never expires) not direct CDN (expires) — consistent with Get-TorboxDirectLinkViaApi
                        if($proxyUp){
                            $map[$fn]=$proxyUrl; $script:torboxLinkCache[$fn]=$proxyUrl
                            Write-BridgeLog "Bulk proxy: $fn -> $proxyUrl (direct $($cdn.Substring(0,[Math]::Min(50,$cdn.Length)))...)"
                        } else {
                            $map[$fn]=$cdn; $script:torboxLinkCache[$fn]=$cdn
                            Write-BridgeLog "Bulk CDN (proxy down): $fn -> $($cdn.Substring(0,[Math]::Min(70,$cdn.Length)))..."
                        }
                    }
                    Start-Sleep -Milliseconds 150
                }catch{ Write-BridgeLog "Bulk requestdl fail $fn : $_" }
            }
        }
    }catch{ Write-BridgeLog "Get-TorboxBulkLinks error: $_" }
    return $map
}
function Invoke-PrefetchCacheEviction([string]$excludePath){
    try{
        $prefetchDirEvict = "F:\Jellyfin\cache\prefetch"
        if(-not (Test-Path -LiteralPath $prefetchDirEvict)){ return }
        [int64]$maxBytes = 20GB
        [double]$maxAgeHours = 24
        $nowUtc = [DateTime]::UtcNow
        $allFiles = @(Get-ChildItem -LiteralPath $prefetchDirEvict -File -ErrorAction SilentlyContinue)
        if($allFiles.Count -eq 0){ return }
        $normExclude = ""
        if($excludePath){
            try{ $normExclude = [System.IO.Path]::GetFullPath($excludePath).ToLowerInvariant() }catch{ $normExclude = ([string]$excludePath).ToLowerInvariant() }
        }
        $candidates = @($allFiles | Where-Object {
            if($normExclude){
                try{ $fp = [System.IO.Path]::GetFullPath($_.FullName).ToLowerInvariant() }catch{ $fp = ([string]$_.FullName).ToLowerInvariant() }
                if($fp -eq $normExclude){ return $false }
            }
            return $true
        } | Sort-Object LastWriteTimeUtc)
        if($candidates.Count -eq 0){ return }
        [int]$evictedCount = 0
        [int64]$evictedBytes = 0
        $remaining = [System.Collections.Generic.List[object]]::new()
        foreach($f in $candidates){
            [double]$ageH = 0
            try{ $ageH = ($nowUtc - $f.LastWriteTimeUtc).TotalHours }catch{ $ageH = 0 }
            if($ageH -gt $maxAgeHours){
                try{
                    [int64]$len = [int64]$f.Length
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                    if(-not (Test-Path -LiteralPath $f.FullName)){ $evictedCount++; $evictedBytes += $len }
                    else { [void]$remaining.Add($f) }
                }catch{ [void]$remaining.Add($f) }
            } else {
                [void]$remaining.Add($f)
            }
        }
        try{
            [int64]$total = 0
            foreach($r in $remaining){ try{ $total += [int64]$r.Length }catch{} }
            if($normExclude){
                try{
                    if(Test-Path -LiteralPath $excludePath){
                        $total += [int64](Get-Item -LiteralPath $excludePath -ErrorAction SilentlyContinue).Length
                    }
                }catch{}
            }
            if($total -gt $maxBytes){
                foreach($f in @($remaining | Sort-Object LastWriteTimeUtc)){
                    if($total -le $maxBytes){ break }
                    try{
                        [int64]$len = [int64]$f.Length
                        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                        if(-not (Test-Path -LiteralPath $f.FullName)){ $evictedCount++; $evictedBytes += $len; $total -= $len }
                    }catch{}
                }
            }
        }catch{}
        if($evictedCount -gt 0){
            $leaf = ""
            try{ $leaf = Split-Path $excludePath -Leaf }catch{}
            Write-BridgeLog "Prefetch LRU evict: $evictedCount file(s), $([math]::Round($evictedBytes/1MB,1)) MB reclaimed (cap 20GB/24h, exclude $leaf)"
        }
    }catch{}
}
function Get-FullCacheFallbackPath([string]$tPath, [string]$itemId){
    try{
        if($tPath -notmatch '^[Tt]:\\') { return $null }
        $rel = $tPath.Substring(3) -replace '\\','/'
        $fileName = Split-Path $rel -Leaf
        $prefetchDir = "F:\Jellyfin\cache\prefetch"
        if(-not (Test-Path $prefetchDir)){ New-Item -ItemType Directory -Path $prefetchDir -Force | Out-Null }
        $safeName = $fileName -replace '[<>:"/\\|?*]','_'
        if($itemId){ $safeName = "$itemId`_$safeName" }
        $localPath = Join-Path $prefetchDir $safeName
        if(Test-Path -LiteralPath $localPath){
            $sz = (Get-Item -LiteralPath $localPath -ErrorAction SilentlyContinue).Length
            if($sz -gt 10MB){
                # Fast HIT: return local prefetch immediately (no blocking rclone size check).
                Write-BridgeLog "Prefetch cache HIT $localPath ($([math]::Round($sz/1MB,1)) MB)"
                return $localPath
            }
        }
        # PRIORITY 1 (GATED): full-file rclone copyto is OFF by default (env FULLCACHE=1 to enable).
        # It had a literal-quote arg bug ("path" passed with embedded quotes) and never HIT, plus a 10s blocking wait per launch.
        if ($env:FULLCACHE -eq '1') {
        try{
            $rcloneExe='F:\Jellyfin\server\rclone.exe'; if(-not (Test-Path $rcloneExe)){ $rcloneExe='rclone' }
            $torboxRel = $rel
            Write-BridgeLog "FULL-CACHE: Starting rclone copyto torbox:$torboxRel -> $localPath"
            $rcArgs = @('copyto', "torbox:$torboxRel", $localPath, '--config', 'F:\Jellyfin\config\rclone.conf', '--transfers', '4', '--checkers', '8', '--buffer-size', '64M', '--log-file', 'F:\Jellyfin\logs\rclone-prefetch.log', '--log-level', 'INFO')
            Start-Process -FilePath $rcloneExe -ArgumentList $rcArgs -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
            # Wait up to 10s for file to appear and grow (>5MB) so PotPlayer doesn't open 0-byte
            for($i=0;$i -lt 10;$i++){
                Start-Sleep -Seconds 1
                if(Test-Path -LiteralPath $localPath){
                    $sz=(Get-Item -LiteralPath $localPath -ErrorAction SilentlyContinue).Length
                    if($sz -gt 5MB){ Write-BridgeLog "FULL-CACHE: Prefetch file ready $localPath ($([math]::Round($sz/1MB,1)) MB) PotPlayer will play local full-cache"; try{ Invoke-PrefetchCacheEviction $localPath }catch{}; return $localPath }
                }
            }
            if(Test-Path -LiteralPath $localPath){
                $sz=(Get-Item -LiteralPath $localPath -ErrorAction SilentlyContinue).Length
                Write-BridgeLog "FULL-CACHE: Using growing local file $localPath (${sz} bytes, still copying in background)"
                try{ Invoke-PrefetchCacheEviction $localPath }catch{}
                return $localPath
            }
            Write-BridgeLog "FULL-CACHE: rclone copy not yet visible after 10s, falling back to CDN"
            try{ Invoke-PrefetchCacheEviction $localPath }catch{}
        }catch{ Write-BridgeLog "FULL-CACHE: rclone copy error $_" }
        } else {
            Write-BridgeLog "FULL-CACHE: copyto skipped (FULLCACHE!=1), using CDN/proxy directly for $fileName"
        }
        # PRIORITY 2: Torbox direct CDN URL (range-capable, but may 429). Only if local copy not yet usable.
        $cdnUrl = Get-TorboxDirectLinkViaApi $tPath
        if($cdnUrl -and $cdnUrl -match "^https?://"){
            Write-BridgeLog "FULL-CACHE: Using Torbox CDN URL (HTTP range-cacheable, not 93-byte Jellyfin stream): $cdnUrl"
            return $cdnUrl
        }
    }catch{ Write-BridgeLog "Get-FullCacheFallbackPath error: $_" }
    return $null
}
if ($mediaPath -like "*.strm" -and (Test-Path -LiteralPath $mediaPath)) {
    try {
        $strmContent = (Get-Content -LiteralPath $mediaPath -Raw -ErrorAction Stop).Trim()
        $firstLine = ($strmContent -split "`r?`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1).Trim()
        if ($firstLine) {
            if ($firstLine.StartsWith("R:\", [System.StringComparison]::OrdinalIgnoreCase)) {
                $firstLine = "F:\Media\" + $firstLine.Substring(3)
            } elseif ($firstLine.StartsWith("R:/", [System.StringComparison]::OrdinalIgnoreCase)) {
                $firstLine = "F:/Media/" + $firstLine.Substring(3)
            }
            if ($firstLine -match "^[a-zA-Z]:") { $firstLine = $firstLine -replace "/", "\" }
            # AUDIT: Log strm resolution attempt
            Write-BridgeLog "STRM resolve: $mediaPath -> $firstLine (exists=$(Test-Path -LiteralPath $firstLine))"
            if ($firstLine -match "^https?://") {
                $mediaPath = $firstLine
            } elseif (Test-Path -LiteralPath $firstLine) {
                # Direct T:\ exists — try Torbox CDN direct link for full-potential buffering (as seen with https://motionpicturepro55.../download.aspx)
                # PotPlayer HTTP progress bar for direct link buffers to full (sequential, large buffer) vs T:\ VFS sparse 256M read-ahead which hikes then tanks (your 0.01->26Mb/s vs 157Mb/s direct). Use CDN when available.
                $cdnDirect = $null
                try{
                    if($firstLine -match "\.(mkv|mp4|avi|ts|m4v|mov|webm|m2ts)$"){
                        $cdnDirect = Get-TorboxDirectLinkViaApi $firstLine
                        if($cdnDirect -and $cdnDirect -match "^https?://"){
                            # Use CDN directly for full-potential HTTP bar (no blocking HEAD — trust requestdl, PotPlayer will handle 429 fallback via T:\ prefetch in 6b)
                            Write-BridgeLog "Direct T exists, using Torbox CDN for full-potential (as direct link): $cdnDirect vs T:\ VFS sparse"
                            $mediaPath = $cdnDirect
                            $script:originalTPathForHttp = $firstLine
                            $script:cdnNiceTitle = Split-Path $firstLine -Leaf
                            $script:cdnItemId = $itemId
                        } else { $mediaPath = $firstLine }
                    } else { $mediaPath = $firstLine }
                } catch { $mediaPath = $firstLine }
            } elseif ($firstLine -match "^[Tt]:\\" -and $firstLine -match "\.(mkv|mp4|avi|ts|m4v|mov|webm|m2ts)$") {
                # EDGE: T:\ path with valid extension but NOT on local VFS -> stale dir-cache (e.g., 9-1-1.S09)
                Write-BridgeLog "AUDIT: Stale VFS cache detected for $firstLine (strm=$mediaPath). Remote exists? Checking..."
                $remoteExists = Test-TorboxRemoteExists $firstLine
                Write-BridgeLog "Remote check result: $remoteExists"
                if($remoteExists -eq $true){
                    Write-BridgeLog "Attempting VFS refresh for stale entry..."
                    Invoke-TorboxVfsRefresh $firstLine | Out-Null
                    Start-Sleep -Milliseconds 1200
                    if(Test-Path -LiteralPath $firstLine){
                        Write-BridgeLog "VFS refresh SUCCESS: $firstLine now visible"
                        $mediaPath = $firstLine
                    } else {
                        Write-BridgeLog "VFS refresh did not expose file yet; triggering FULL-CACHE fallback (torbox direct / rclone copy)"
                        $fullCachePath = Get-FullCacheFallbackPath $firstLine $itemId
                        if($fullCachePath){
                            Write-BridgeLog "FALLBACK: Using FULL-CACHE path for stale T:\\ : $fullCachePath"
                            $mediaPath = $fullCachePath
                            if($fullCachePath -match "^https?://" -and $fullCachePath -match "tb-cdn|workers\.dev|127\.0\.0\.1:8888"){
                                $script:originalTPathForHttp = $firstLine
                                $script:cdnNiceTitle = Split-Path $firstLine -Leaf
                                $script:cdnItemId = $itemId
                            }
                        } elseif($itemId -and $userId -and $token){
                            $fallbackUrl = $serverUrl.TrimEnd('/') + "/Videos/$itemId/stream?static=true&api_key=$token"
                            Write-BridgeLog "FALLBACK: Full-cache unavailable, using Jellyfin stream URL (may not cache full): $fallbackUrl"
                            $mediaPath = $fallbackUrl
                        } else {
                            Write-BridgeLog "FALLBACK: No credentials for HTTP fallback, will handle in 5c"
                            $script:staleStrmDetected = $true
                            $script:staleStrmTarget = $firstLine
                        }
                    }
                } else {
                    Write-BridgeLog "Remote also missing or check inconclusive; not using broken T:\\ path"
                    $script:staleStrmDetected = $true
                    $script:staleStrmTarget = $firstLine
                }
            } else {
                Write-BridgeLog "STRM target invalid or not http/existing: $firstLine - keeping strm path for 5c fallback"
            }
        }
    } catch { Write-BridgeLog "STRM resolve error: $_" }
}

# 5c. Global validation + fallback: handle both direct missing files AND unresolved stale .strm where T:\ target was missing
# Also convert F:\Media / G:\ (Google Drive) direct files to HTTP proxy for bar (like Torbox) — so Cursed S01E01 shows progress bar too
if ($mediaPath -match '^[FG]:\\' -and (Test-Path -LiteralPath $mediaPath) -and $mediaPath -match "\.(mkv|mp4|avi|ts|m4v|mov|webm|m2ts)$") {
    try{
        $relG = $mediaPath -replace '^[FG]:\\Media\\','' -replace '^[FG]:\\','' -replace '\\','/'
        $relG = $relG -replace '^Series/','Series/' -replace '^Movies/','Movies/'
        # For F:\Media\Series\Cursed... rel is Series/Cursed...
        # For G:\Series\Cursed... rel is Series/Cursed...
        if($mediaPath -match '^[FG]:\\Media\\'){ $relG = $mediaPath.Substring(9) -replace '\\','/' } # F:\Media\ -> after 9 chars
        elseif($mediaPath -match '^G:\\'){ $relG = $mediaPath.Substring(3) -replace '\\','/' }
        $proxyG = "http://127.0.0.1:8888/gdrive/$([Uri]::EscapeDataString($relG).Replace('%2F','/').Replace('%5C','/'))"
        # Use proxy for Google Drive too so bar fills (HTTP progressive vs G:\ VFS sparse 128M)
        # Keep original for fallback if proxy not running. Single cached probe per launch.
        if (Test-ProxyHealthCached) {
            Write-BridgeLog "GDrive F:\Media/G:\ exists, using proxy for bar: $proxyG vs $mediaPath"
            $script:originalTPathForHttp = $mediaPath
            $script:cdnNiceTitle = Split-Path $mediaPath -Leaf
            $script:cdnItemId = $itemId
            $mediaPath = $proxyG
        } else { Write-BridgeLog "Proxy not running for GDrive, keeping $mediaPath" }
    } catch { Write-BridgeLog "GDrive proxy convert fail $_" }
}
# Case A: mediaPath itself missing (e.g., direct T:\ path)
# Case B: mediaPath is still the .strm because T:\ resolution failed (stale)
$needFallback = $false
$fallbackReason = ""
if ($mediaPath -match '^[a-zA-Z]:[\\/]' -and -not (Test-Path -LiteralPath $mediaPath) -and $mediaPath -notmatch '^https?://') {
    $needFallback = $true
    $fallbackReason = "direct missing file"
} elseif ($mediaPath -like "*.strm" -and (Test-Path -LiteralPath $mediaPath) -and $script:staleStrmDetected) {
    $needFallback = $true
    $fallbackReason = "stale strm target missing ($script:staleStrmTarget)"
}
if ($needFallback) {
    Write-BridgeLog "GLOBAL FIX: Final path missing on disk: $mediaPath (itemId=$itemId). Auditing remedy..."
    # Try VFS refresh once more for T:\ paths
    if($mediaPath -match '^[Tt]:\\'){
        Invoke-TorboxVfsRefresh $mediaPath | Out-Null
        Start-Sleep -Milliseconds 800
        if(Test-Path -LiteralPath $mediaPath){
            Write-BridgeLog "GLOBAL FIX: VFS refresh recovered missing T:\\ path"
        }
    }
    if(-not (Test-Path -LiteralPath $mediaPath)){
        # Try full-cache capable fallback first (Torbox CDN + rclone prefetch) — Jellyfin stream returns 93-byte .strm, not video, so not cacheable
        $fallbackTarget = if($script:staleStrmTarget){ $script:staleStrmTarget } else { $mediaPath }
        $fullCache = $null
        if($fallbackTarget -match '^[Tt]:\\'){
            $fullCache = Get-FullCacheFallbackPath $fallbackTarget $itemId
        }
        if($fullCache){
            Write-BridgeLog "FALLBACK: Using FULL-CACHE path for missing file: $fullCache (reason: $fallbackReason)"
            $mediaPath = $fullCache
            # UNIVERSAL: For T:\ stale with 1 file, ensure playlist will be full via HTTP proxy bulk, not 1 — set originalTPath for HTTP playlist generation
            if($fullCache -match "127\.0\.0\.1:8888/torbox" -and $fallbackTarget -match "^[Tt]:\\"){
                $script:originalTPathForHttp = $fallbackTarget
                $script:cdnNiceTitle = Split-Path $fallbackTarget -Leaf
                $script:cdnItemId = $itemId
                Write-BridgeLog "Set originalTPathForHttp for stale T:\ -> HTTP playlist universal: $fallbackTarget"
            }
        } elseif($itemId -and $userId -and $token){
            $streamUrl = $serverUrl.TrimEnd('/') + "/Videos/$itemId/stream?static=true&api_key=$token"
            Write-BridgeLog "FALLBACK: Full-cache unavailable, using Jellyfin stream URL (may not cache full, 93-byte .strm risk): $streamUrl"
            $mediaPath = $streamUrl
            try{ Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue }catch{}
        } else {
            Write-BridgeLog "ERROR: No Jellyfin credentials and no full-cache path for missing file: $mediaPath"
        }
    }
}


$potExe = 'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe'
if (-not (Test-Path -LiteralPath $potExe)) {
    $altPot = 'C:\Program Files (x86)\DAUM\PotPlayer\PotPlayerMini64.exe'
    if (Test-Path -LiteralPath $altPot) { $potExe = $altPot }
}

# 5b. Watch console: visible live logs while watching (singleton, new episode takes over). Opt out with NOWATCH=1.
$script:resumeSec = 0
try {
    if ($env:NOWATCH -ne '1') {
        $watchHint = ($mediaPath -split '[/\\]' | Select-Object -Last 1)
        if (-not $watchHint) { $watchHint = [string]$mediaPath }
        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", "`"F:\Jellyfin\show-playback-log.ps1`"", "-EpisodeHint", "`"$watchHint`"", "-ItemId", "`"$itemId`"" -WindowStyle Normal -ErrorAction SilentlyContinue | Out-Null
    }
} catch {}
# 5c. Resume: ask Jellyfin where this episode left off so PotPlayer can /seek there (tracker keeps counting from it).
try {
    if ($itemId -and $userId -and $token) {
        $authH = @{ Authorization = "MediaBrowser Client=`"PotPlayer`", Device=`"Windows`", DeviceId=`"PotPlayer-Win32`", Version=`"1.0.0`", Token=`"$token`"" }
        $ud = Invoke-RestMethod -Uri ($serverUrl.TrimEnd('/') + "/Users/$userId/Items/$itemId/UserData") -Method GET -Headers $authH -TimeoutSec 5 -ErrorAction SilentlyContinue
        $ppt = $null
        if ($ud.PlaybackPositionTicks) { $ppt = $ud.PlaybackPositionTicks }
        elseif ($ud.UserData.PlaybackPositionTicks) { $ppt = $ud.UserData.PlaybackPositionTicks }
        if ($ppt -gt 0) { $script:resumeSec = [int]([double]$ppt / 10000000.0) }
        if ($script:resumeSec -gt 0) { Write-BridgeLog "RESUME: $itemId at $($script:resumeSec)s" }
    }
} catch {}

# 6. Launch background playback sync tracker if credentials/itemId provided
if ($itemId -and $userId -and $token) {
    $trackerScript = 'F:\Jellyfin\potplayer-sync-tracker.ps1'
    if (Test-Path -LiteralPath $trackerScript) {
        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", "`"$trackerScript`"", "-MediaPath", "`"$mediaPath`"", "-ItemId", "`"$itemId`"", "-UserId", "`"$userId`"", "-Token", "`"$token`"", "-ServerUrl", "`"$serverUrl`""
    }
}
# 6b. GLOBAL FULL-CACHE prefetch for T:\ direct play — GATED behind env FULLCACHE=1 (default OFF).
# Previously ran a blocking rclone size + copyto with literal-quote arg bug on every T:\ launch and never HIT.
if ($env:FULLCACHE -eq '1' -and $mediaPath -match '^[Tt]:\\' -and (Test-Path -LiteralPath $mediaPath)) {
    try{
        $relPrefetch = $mediaPath.Substring(3) -replace '\\','/'
        $prefetchDir = "F:\Jellyfin\cache\prefetch"
        if(-not (Test-Path $prefetchDir)){ New-Item -ItemType Directory -Path $prefetchDir -Force | Out-Null }
        $safePrefetch = (Split-Path $mediaPath -Leaf) -replace '[<>:"/\\|?*]','_'
        if($itemId){ $safePrefetch = "${itemId}_$safePrefetch" }
        $prefetchPath = Join-Path $prefetchDir $safePrefetch
        $rcloneExe='F:\Jellyfin\server\rclone.exe'; if(-not (Test-Path $rcloneExe)){ $rcloneExe='rclone' }
        # Only start if not already fully cached (check size)
        $needPrefetch = $true
        if(Test-Path -LiteralPath $prefetchPath){
            $localSz=(Get-Item -LiteralPath $prefetchPath -ErrorAction SilentlyContinue).Length
            $remoteSz=0
            try{ $sizeJson=& $rcloneExe --config "F:\Jellyfin\config\rclone.conf" size "torbox:$relPrefetch" --json 2>$null | Out-String; if($sizeJson -match '"bytes"\s*:\s*(\d+)'){ $remoteSz=[int64]$Matches[1] } }catch{}
            if($remoteSz -gt 0 -and [math]::Abs($localSz - $remoteSz) -lt 5MB){ $needPrefetch=$false; Write-BridgeLog "Prefetch already full $prefetchPath ($([math]::Round($localSz/1MB,1)) MB)" }
        }
        if($needPrefetch){
            Write-BridgeLog "FULL-CACHE prefetch start for direct T:\ play: torbox:$relPrefetch -> $prefetchPath (background, 60G cache)"
            $bgArgs=@('copyto', "torbox:$relPrefetch", $prefetchPath, '--config', 'F:\Jellyfin\config\rclone.conf', '--transfers', '4', '--checkers', '8', '--buffer-size', '64M', '--log-file', 'F:\Jellyfin\logs\rclone-prefetch.log', '--log-level', 'INFO')
            Start-Process -FilePath $rcloneExe -ArgumentList $bgArgs -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
            # Also trigger VFS full fetch via RC if available (makes T:\ sparse cache grow faster)
            try{ Invoke-RestMethod -Uri 'http://127.0.0.1:5572/vfs/cache/fetch' -Method POST -Body (@{file=$mediaPath}|ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 2 -ErrorAction SilentlyContinue | Out-Null; Write-BridgeLog "VFS cache fetch queued for $mediaPath" }catch{}
        }
        try{ Invoke-PrefetchCacheEviction $prefetchPath }catch{}
    }catch{ Write-BridgeLog "Prefetch trigger error: $_" }
}

function Show-MissingFileDialog([string]$path, [string]$itemId){
    try{
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $msg = "File not found on T:\ drive:`n`n$path`n`nThis usually means the Torbox rclone cache was stale (dir-cache-time was 500h).`n`nGlobal fix applied:`n• VFS cache now 30s + auto-refresh`n• Fallback to Jellyfin HTTP stream when local file missing`n`nIf you still see this, click OK to try streaming via Jellyfin (if itemId: $itemId) or restart 'mount_torbox'."
        [System.Windows.Forms.MessageBox]::Show($msg, "PotPlayer Launcher - File Missing (Global Fix Active)", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }catch{}
    Write-BridgeLog "SHOW_DIALOG: Missing file dialog shown for $path"
}

# Reliable episode-playlist rules:
# 1. Merge the visible local season directory.
# 2. Merge an authoritative rclone remote listing when the mount is stale.
# 3. Merge Jellyfin's season API when either filesystem path is incomplete.
# 4. Keep a validated target-only .dpl as the final safe fallback; never write an empty or stale entry.
$script:ReliablePlaylistExtensions = @('.mkv', '.mp4', '.avi', '.ts', '.m4v', '.mov', '.webm', '.flv', '.wmv', '.m2ts', '.strm')

function Test-ReliablePlaylistMediaName([string]$Name){
    if([string]::IsNullOrWhiteSpace($Name)){ return $false }
    return ($script:ReliablePlaylistExtensions -contains ([System.IO.Path]::GetExtension($Name).ToLowerInvariant()))
}

function ConvertTo-ReliableJellyfinId([string]$Id){
    if([string]::IsNullOrWhiteSpace($Id)){ return '' }
    if($Id -match '^[0-9a-fA-F]{32}$'){
        return (($Id -replace '^(.{8})(.{4})(.{4})(.{4})(.{12})$','$1-$2-$3-$4-$5').ToLowerInvariant())
    }
    return $Id
}

function Resolve-ReliablePlaylistSource([string]$Path){
    if([string]::IsNullOrWhiteSpace($Path)){ return '' }
    $source = $Path.Trim().Trim('"').Trim("'")
    if($source -match '^https?://'){ return $source }

    if($source.StartsWith('R:\', [System.StringComparison]::OrdinalIgnoreCase)){
        $source = 'F:\Media\' + $source.Substring(3)
    } elseif($source.StartsWith('R:/', [System.StringComparison]::OrdinalIgnoreCase)){
        $source = 'F:/Media/' + $source.Substring(3)
    }
    if($source -match '^[a-zA-Z]:'){ $source = $source -replace '/', '\' }

    if($source -match '\.strm$' -and (Test-Path -LiteralPath $source -PathType Leaf)){
        try{
            $content = Get-Content -LiteralPath $source -Raw -ErrorAction Stop
            $line = @($content -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)[0]
            if($line){
                $line = $line.Trim().Trim('"').Trim("'")
                if($line.StartsWith('R:\', [System.StringComparison]::OrdinalIgnoreCase)){
                    $line = 'F:\Media\' + $line.Substring(3)
                } elseif($line.StartsWith('R:/', [System.StringComparison]::OrdinalIgnoreCase)){
                    $line = 'F:/Media/' + $line.Substring(3)
                }
                if($line -match '^[a-zA-Z]:'){ $line = $line -replace '/', '\' }
                $source = $line
            }
        } catch {}
    }
    return $source
}

function Get-ReliablePlaylistLocalCandidates([string]$SourcePath){
    $source = Resolve-ReliablePlaylistSource $SourcePath
    if($source -match '^https?://'){ return @() }
    $parent = ''
    try{ $parent = [System.IO.Path]::GetDirectoryName($source) }catch{}
    if([string]::IsNullOrWhiteSpace($parent) -or -not (Test-Path -LiteralPath $parent -PathType Container)){ return @() }
    try{
        $files = @(Get-ChildItem -LiteralPath $parent -File -ErrorAction Stop | Where-Object { Test-ReliablePlaylistMediaName ([string]$_.Name) })
        foreach($file in $files){
            [PSCustomObject]@{
                Name = [string]$file.Name
                SourcePath = [string]$file.FullName
                OriginalPath = [string]$file.FullName
                JellyfinItemId = ''
                Tier = 'local'
            }
        }
    } catch { return @() }
}

function Get-ReliablePlaylistRemoteSpec([string]$SourcePath){
    $source = Resolve-ReliablePlaylistSource $SourcePath
    if($source -match '^T:\\'){
        $relative = $source.Substring(3) -replace '\\','/'
        $kind = 'torbox'
        $remoteRoot = 'torbox:'
    } elseif($source -match '^F:\\Media\\'){
        $relative = $source.Substring(9) -replace '\\','/'
        $kind = 'gdrive'
        $remoteRoot = 'gdrive-media:'
    } elseif($source -match '^G:\\'){
        $relative = $source.Substring(3) -replace '\\','/'
        $kind = 'gdrive'
        $remoteRoot = 'gdrive-media:'
    } else {
        return $null
    }
    $parent = [System.IO.Path]::GetDirectoryName($relative)
    if($parent){ $parent = $parent -replace '\\','/' } else { $parent = '' }
    [PSCustomObject]@{
        Kind = $kind
        RemoteRoot = $remoteRoot
        Parent = $parent
        LocalParent = [System.IO.Path]::GetDirectoryName($source)
    }
}

function Get-ReliablePlaylistRemoteCandidates([string]$SourcePath){
    $spec = Get-ReliablePlaylistRemoteSpec $SourcePath
    if($null -eq $spec -or [string]::IsNullOrWhiteSpace($spec.LocalParent)){ return @() }
    $rcloneExe = 'F:\Jellyfin\server\rclone.exe'
    if(-not (Test-Path -LiteralPath $rcloneExe -PathType Leaf)){
        $command = Get-Command rclone.exe -ErrorAction SilentlyContinue
        if($command){ $rcloneExe = $command.Source } else { return @() }
    }
    $remotePath = $spec.RemoteRoot + $spec.Parent
    try{
        $raw = & $rcloneExe --config 'F:\Jellyfin\config\rclone.conf' lsjson $remotePath 2>$null | Out-String
        if([string]::IsNullOrWhiteSpace($raw)){ return @() }
        $records = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
        foreach($record in $records){
            if($record.IsDir){ continue }
            $name = [string]$record.Name
            if(-not $name -and $record.Path){ $name = [string]$record.Path }
            if([string]::IsNullOrWhiteSpace($name)){ continue }
            $name = [System.IO.Path]::GetFileName($name.Replace('/','\'))
            if(-not (Test-ReliablePlaylistMediaName $name)){ continue }
            [PSCustomObject]@{
                Name = $name
                SourcePath = Join-Path $spec.LocalParent $name
                OriginalPath = Join-Path $spec.LocalParent $name
                JellyfinItemId = ''
                Tier = 'rclone'
            }
        }
    } catch { return @() }
}

function Get-ReliablePlaylistJellyfinCandidates([string]$SelectedItemId, [string]$Server, [string]$User, [string]$ApiToken){
    if([string]::IsNullOrWhiteSpace($SelectedItemId) -or [string]::IsNullOrWhiteSpace($Server) -or [string]::IsNullOrWhiteSpace($User) -or [string]::IsNullOrWhiteSpace($ApiToken)){ return @() }
    try{
        $id = ConvertTo-ReliableJellyfinId $SelectedItemId
        $headers = @{ 'X-Emby-Token' = $ApiToken }
        $itemUrl = $Server.TrimEnd('/') + '/Users/' + $User + '/Items/' + $id + '?Fields=SeriesId,SeasonId,ParentId,Path,Type,IndexNumber,ParentIndexNumber'
        $selected = Invoke-RestMethod -Uri $itemUrl -Headers $headers -TimeoutSec 8 -ErrorAction Stop
        $seriesId = [string]$selected.SeriesId
        $seasonId = [string]$selected.SeasonId
        if($selected.Type -eq 'Season'){
            $seasonId = [string]$selected.Id
            if(-not $seriesId){ $seriesId = [string]$selected.SeriesId }
        }
        if(-not $seasonId -and $selected.ParentId){ $seasonId = [string]$selected.ParentId }
        if([string]::IsNullOrWhiteSpace($seriesId) -or [string]::IsNullOrWhiteSpace($seasonId)){ return @() }
        $episodesUrl = $Server.TrimEnd('/') + '/Shows/' + (ConvertTo-ReliableJellyfinId $seriesId) + '/Episodes?SeasonId=' + (ConvertTo-ReliableJellyfinId $seasonId) + '&UserId=' + $User + '&Limit=500&Fields=Path,Name,IndexNumber,ParentIndexNumber,SeasonId'
        $episodeResult = Invoke-RestMethod -Uri $episodesUrl -Headers $headers -TimeoutSec 12 -ErrorAction Stop
        foreach($episode in @($episodeResult.Items)){
            $path = [string]$episode.Path
            if([string]::IsNullOrWhiteSpace($path)){ continue }
            $name = [System.IO.Path]::GetFileName($path)
            if(-not (Test-ReliablePlaylistMediaName $name)){ continue }
            $epIdx = $null
            try{ if($null -ne $episode.IndexNumber){ $epIdx = [int]$episode.IndexNumber } }catch{}
            $epParentIdx = $null
            try{ if($null -ne $episode.ParentIndexNumber){ $epParentIdx = [int]$episode.ParentIndexNumber } }catch{}
            [PSCustomObject]@{
                Name = $name
                SourcePath = $path
                OriginalPath = $path
                JellyfinItemId = [string]$episode.Id
                JellyfinIndexNumber = $epIdx
                JellyfinParentIndexNumber = $epParentIdx
                Tier = 'jellyfin'
            }
        }
    } catch { return @() }
}

function Test-ReliablePlaylistProxy {
    # Wrapper over the single cached probe — never probe per-file in a loop.
    return (Test-ProxyHealthCached)
}

function New-ReliableGDrivePlaylistUrl([string]$SourcePath){
    $source = Resolve-ReliablePlaylistSource $SourcePath
    $relative = ''
    if($source -match '^F:\\Media\\'){ $relative = $source.Substring(9) -replace '\\','/' }
    elseif($source -match '^G:\\'){ $relative = $source.Substring(3) -replace '\\','/' }
    else { return '' }
    $escaped = [Uri]::EscapeDataString($relative).Replace('%2F','/').Replace('%5C','/')
    return 'http://127.0.0.1:8888/gdrive/' + $escaped
}

function New-ReliableJellyfinStreamUrl([string]$CandidateItemId, [string]$Server, [string]$ApiToken){
    if([string]::IsNullOrWhiteSpace($CandidateItemId) -or [string]::IsNullOrWhiteSpace($Server) -or [string]::IsNullOrWhiteSpace($ApiToken)){ return '' }
    return $Server.TrimEnd('/') + '/Videos/' + (ConvertTo-ReliableJellyfinId $CandidateItemId) + '/stream?static=true&api_key=' + $ApiToken
}

function Test-ReliablePlaylistOutput([string]$Path){
    if([string]::IsNullOrWhiteSpace($Path)){ return $false }
    if($Path -match '^https?://'){ return $true }
    try{ return (Test-Path -LiteralPath $Path -PathType Leaf) }catch{ return $false }
}

function Resolve-ReliablePlaylistEntry([object]$Candidate, [hashtable]$TorboxLinks, [bool]$ProxyAvailable, [string]$Server, [string]$ApiToken){
    $source = Resolve-ReliablePlaylistSource ([string]$Candidate.SourcePath)
    if([string]::IsNullOrWhiteSpace($source)){ return '' }
    if($source -match '^https?://'){ return $source }
    if($source -match '\.strm$'){ return '' }
    $name = [System.IO.Path]::GetFileName($source)
    $original = [string]$Candidate.OriginalPath
    if($source -match '^T:\\'){
        if($TorboxLinks -and $TorboxLinks.ContainsKey($name) -and (Test-ReliablePlaylistOutput ([string]$TorboxLinks[$name]))){ return [string]$TorboxLinks[$name] }
        if(Test-ReliablePlaylistOutput $source){ return $source }
        if($Candidate.JellyfinItemId -and $original -notmatch '\.strm$'){
            return New-ReliableJellyfinStreamUrl ([string]$Candidate.JellyfinItemId) $Server $ApiToken
        }
        return ''
    }
    if($source -match '^F:\\Media\\' -or $source -match '^G:\\'){
        if($ProxyAvailable){ return New-ReliableGDrivePlaylistUrl $source }
        if(Test-ReliablePlaylistOutput $source){ return $source }
        if($Candidate.JellyfinItemId -and $original -notmatch '\.strm$'){
            return New-ReliableJellyfinStreamUrl ([string]$Candidate.JellyfinItemId) $Server $ApiToken
        }
        return ''
    }
    if(Test-ReliablePlaylistOutput $source){ return $source }
    if($Candidate.JellyfinItemId -and $original -notmatch '\.strm$'){
        return New-ReliableJellyfinStreamUrl ([string]$Candidate.JellyfinItemId) $Server $ApiToken
    }
    return ''
}

function Write-ReliablePlaylistFile([object[]]$Entries, [int]$TargetIndex, [string]$Identity){
    if($Entries.Count -eq 0 -or $TargetIndex -lt 0 -or $TargetIndex -ge $Entries.Count){ return '' }
    $playlistDir = 'F:\Jellyfin\cache\playlists'
    if(-not (Test-Path -LiteralPath $playlistDir -PathType Container)){ New-Item -ItemType Directory -Path $playlistDir -Force | Out-Null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try{
        $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Identity)))).Replace('-','').Substring(0,16).ToLowerInvariant()
    } finally { $sha.Dispose() }
    $playlistPath = Join-Path $playlistDir ('potplayer-reliable-' + $hash + '.dpl')
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add('DAUMPLAYLIST')
    [void]$lines.Add('playname=' + [string]$Entries[$TargetIndex].PlayPath)
    [void]$lines.Add('playindex=' + $TargetIndex)
    [void]$lines.Add('topindex=0')
    $count = 1
    foreach($entry in $Entries){
        [void]$lines.Add("$count`*file*" + [string]$entry.PlayPath)
        [void]$lines.Add("$count`*title*" + [string]$entry.Name)
        $count++
    }
    [System.IO.File]::WriteAllLines($playlistPath, $lines, [Text.Encoding]::Unicode)
    return $playlistPath
}

# --- INSTANT-START single playlist (default) + lazy next ---
# New-SinglePlaylist: 1-entry .dpl (playindex=0, playname, topindex) for instant start.
# Launched as: PotPlayerMini64.exe "single.dpl" /current
function New-SinglePlaylist([string]$PlayPath, [string]$Title, [string]$Identity) {
    if ([string]::IsNullOrWhiteSpace($PlayPath)) { return '' }
    if ([string]::IsNullOrWhiteSpace($Title)) { try { $Title = [System.IO.Path]::GetFileNameWithoutExtension($PlayPath.Split('?')[0]) } catch { $Title = $PlayPath } }
    if ([string]::IsNullOrWhiteSpace($Identity)) { $Identity = $PlayPath }
    $playlistDir = 'F:\Jellyfin\cache\playlists'
    if (-not (Test-Path -LiteralPath $playlistDir -PathType Container)) { New-Item -ItemType Directory -Path $playlistDir -Force | Out-Null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Identity)))).Replace('-', '').Substring(0, 16).ToLowerInvariant()
    } finally { $sha.Dispose() }
    $playlistPath = Join-Path $playlistDir ('potplayer-single-' + $hash + '.dpl')
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add('DAUMPLAYLIST')
    [void]$lines.Add('playname=' + $PlayPath)
    [void]$lines.Add('playindex=0')
    [void]$lines.Add('topindex=0')
    [void]$lines.Add('1*file*' + $PlayPath)
    [void]$lines.Add('1*title*' + $Title)
    [System.IO.File]::WriteAllLines($playlistPath, $lines, [Text.Encoding]::Unicode)
    return $playlistPath
}

# Resolve ONLY the selected entry to a playable URL/path (no season enumeration, no bulk E+2..).
function Resolve-SinglePlayPath([string]$SelectedPath) {
    try {
        $src = if ($script:originalTPathForHttp) { Resolve-ReliablePlaylistSource ([string]$script:originalTPathForHttp) } else { Resolve-ReliablePlaylistSource $SelectedPath }
        if ([string]::IsNullOrWhiteSpace($src)) { $src = $SelectedPath }
        if ($src -match '^https?://') { return $src }
        if ($src -match '\.strm$') { return '' }
        if ($src -match '^T:\\') {
            $leaf = [System.IO.Path]::GetFileName($src)
            try {
                # Single-file Torbox resolve reusing Get-TorboxBulkLinks cache (mylist cached 60s, link cache per filename).
                $m = Get-TorboxBulkLinks @($leaf)
                if ($m -and $m.ContainsKey($leaf) -and (Test-ReliablePlaylistOutput ([string]$m[$leaf]))) { return [string]$m[$leaf] }
            } catch {}
            if (Test-ReliablePlaylistOutput $src) { return $src }
            return ''
        }
        if ($src -match '^F:\\Media\\' -or $src -match '^G:\\') {
            if (Test-ProxyHealthCached) {
                $u = New-ReliableGDrivePlaylistUrl $src
                if ($u) { return $u }
            }
            if (Test-ReliablePlaylistOutput $src) { return $src }
            return ''
        }
        if (Test-ReliablePlaylistOutput $src) { return $src }
        return ''
    } catch { return '' }
}

function Get-SingleNiceTitle([string]$SelectedPath, [string]$PlayPath) {
    try {
        if ($script:cdnNiceTitle) { return [System.IO.Path]::GetFileNameWithoutExtension([string]$script:cdnNiceTitle) }
        $src = if ($script:originalTPathForHttp) { [string]$script:originalTPathForHttp } else { $SelectedPath }
        $t = [System.IO.Path]::GetFileNameWithoutExtension($src)
        if ([string]::IsNullOrWhiteSpace($t) -or $t -match '^[a-f0-9\-]{30,}') {
            $t = [System.IO.Path]::GetFileNameWithoutExtension($PlayPath.Split('?')[0])
        }
        return $t
    } catch { return 'PotPlayer' }
}

# Lazy next: background hidden powershell resolves ONLY selected+1 and appends via PotPlayer /add.
# Never pre-resolves E+2.. in the foreground launch path.
function Start-LazyNextAppend([string]$SelectedPath) {
    try {
        $toB64 = { param([string]$s) if ([string]::IsNullOrEmpty($s)) { return '' }; return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
        $encSel = & $toB64 $SelectedPath
        $encItem = & $toB64 ([string]$itemId)
        $encUser = & $toB64 ([string]$userId)
        $encTok = & $toB64 ([string]$token)
        $encSrv = & $toB64 ([string]$serverUrl)
        $encPot = & $toB64 $potExe
        # Temp worker reuses this launcher's functions via dot-source (dot-source is side-effect free:
        # empty rawArgs returns early, final launch is guarded by InvocationName check).
        $worker = Join-Path 'F:\Jellyfin\cache\playlists' ('lazy-next-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
        $workerCode = @'
param([string]$B64Sel,[string]$B64Item,[string]$B64User,[string]$B64Tok,[string]$B64Srv,[string]$B64Pot)
Start-Sleep -Milliseconds 2500
. 'F:\Jellyfin\potplayer-launcher.ps1'
Invoke-LazyNextWorker $B64Sel $B64Item $B64User $B64Tok $B64Srv $B64Pot
'@
        Set-Content -LiteralPath $worker -Value $workerCode -Encoding UTF8 -ErrorAction Stop
        # Pass b64 args positionally (no -LazyNextAppend switch needed; worker script has explicit params).
        $wArgs = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $worker, $encSel, $encItem, $encUser, $encTok, $encSrv, $encPot)
        Write-BridgeLog "LAZY-NEXT: queued background resolve for selected+1 only (no E+2.. pre-resolve)"
        Start-Process -FilePath 'powershell.exe' -ArgumentList $wArgs -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
    } catch { Write-BridgeLog "LAZY-NEXT queue failed: $_" }
}

# Handles the detached lazy-next worker invoked as: launcher -LazyNextAppend <b64sel> <b64item> <b64user> <b64tok> <b64srv> <b64pot>
function Invoke-LazyNextWorker([string]$B64Sel, [string]$B64Item, [string]$B64User, [string]$B64Tok, [string]$B64Srv, [string]$B64Pot) {
    try {
        $dec = { param([string]$b) try { if ([string]::IsNullOrWhiteSpace($b)) { return '' }; return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)) } catch { return '' } }
        $selPath = & $dec $B64Sel
        $wItem = & $dec $B64Item
        $wUser = & $dec $B64User
        $wTok = & $dec $B64Tok
        $wSrv = & $dec $B64Srv
        $wPot = & $dec $B64Pot
        if ([string]::IsNullOrWhiteSpace($wPot)) { $wPot = 'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe' }
        if ([string]::IsNullOrWhiteSpace($selPath)) { return }
        $nextPlay = ''
        $nextTitle = ''
        # Path 1: Jellyfin next episode (single IndexNumber+1 lookup, not full playlist).
        if ($wItem -and $wUser -and $wTok -and $wSrv) {
            try {
                $wid = $wItem; if ($wid -match '^[0-9a-fA-F]{32}$') { $wid = ($wid -replace '^(.{8})(.{4})(.{4})(.{4})(.{12})$', '$1-$2-$3-$4-$5').ToLowerInvariant() }
                $headers = @{ 'X-Emby-Token' = $wTok }
                $cur = Invoke-RestMethod -Uri ($wSrv.TrimEnd('/') + '/Users/' + $wUser + '/Items/' + $wid + '?Fields=SeriesId,SeasonId,IndexNumber') -Headers $headers -TimeoutSec 8 -ErrorAction Stop
                $seriesId = [string]$cur.SeriesId; $seasonId = [string]$cur.SeasonId; $idx = [int]$cur.IndexNumber
                if ($seriesId -and $seasonId -and $idx -ge 0) {
                    if ($seriesId -match '^[0-9a-fA-F]{32}$') { $seriesId = ($seriesId -replace '^(.{8})(.{4})(.{4})(.{4})(.{12})$', '$1-$2-$3-$4-$5').ToLowerInvariant() }
                    if ($seasonId -match '^[0-9a-fA-F]{32}$') { $seasonId = ($seasonId -replace '^(.{8})(.{4})(.{4})(.{4})(.{12})$', '$1-$2-$3-$4-$5').ToLowerInvariant() }
                    $eps = Invoke-RestMethod -Uri ($wSrv.TrimEnd('/') + '/Shows/' + $seriesId + '/Episodes?SeasonId=' + $seasonId + '&UserId=' + $wUser + '&Limit=500&Fields=Path,IndexNumber') -Headers $headers -TimeoutSec 10 -ErrorAction Stop
                    $next = @($eps.Items | Where-Object { [int]$_.IndexNumber -eq ($idx + 1) } | Select-Object -First 1)[0]
                    if ($next) {
                        $nPath = [string]$next.Path; $nId = [string]$next.Id
                        $nName = if ($nPath) { [System.IO.Path]::GetFileName($nPath) } else { '' }
                        if ($nPath -match '^[Tt]:\\' -and $nName) {
                            try {
                                # Reuse bulk cache pattern for exactly one file.
                                $one = Get-TorboxBulkLinks @($nName)
                                if ($one.ContainsKey($nName)) { $nextPlay = [string]$one[$nName] }
                            } catch {}
                            if (-not $nextPlay -and (Test-Path -LiteralPath $nPath)) { $nextPlay = $nPath }
                            if (-not $nextPlay -and $nId) { $nextPlay = $wSrv.TrimEnd('/') + '/Videos/' + $nId + '/stream?static=true&api_key=' + $wTok }
                        } elseif ($nPath -match '^[FG]:\\|^G:\\') {
                            if (Test-ProxyHealthCached) { $nextPlay = New-ReliableGDrivePlaylistUrl $nPath }
                            if (-not $nextPlay) { $nextPlay = $nPath }
                        } elseif ($nPath) { $nextPlay = $nPath }
                        elseif ($nId) { $nextPlay = $wSrv.TrimEnd('/') + '/Videos/' + $nId + '/stream?static=true&api_key=' + $wTok }
                        if ($nName) { $nextTitle = [System.IO.Path]::GetFileNameWithoutExtension($nName) }
                    }
                }
            } catch {}
        }
        # Path 2: filename SxxEyy increment for exactly one sibling (no directory-wide bulk resolve).
        if (-not $nextPlay) {
            try {
                $leaf = [System.IO.Path]::GetFileName($selPath)
                if ($leaf -match '(?i)(S(\d{1,3})E(\d{1,4}))') {
                    $sNum = $Matches[2]; $eNum = [int]$Matches[3]
                    $nextTag = ('S{0}E{1}' -f $sNum.PadLeft(2, '0'), ($eNum + 1).ToString().PadLeft(2, '0'))
                    $curTag = $Matches[1]
                    $nextLeafGuess = $leaf -replace [regex]::Escape($curTag), $nextTag
                    # Single local hit check first (no enumeration of E+2..).
                    try {
                        $parent = [System.IO.Path]::GetDirectoryName((Resolve-ReliablePlaylistSource $selPath))
                        if ($parent -and (Test-Path -LiteralPath $parent -PathType Container)) {
                            $cand = Join-Path $parent $nextLeafGuess
                            if (Test-Path -LiteralPath $cand -PathType Leaf) {
                                $one2 = $null
                                try { $one2 = Get-TorboxBulkLinks @($nextLeafGuess) } catch {}
                                if ($one2 -and $one2.ContainsKey($nextLeafGuess)) { $nextPlay = [string]$one2[$nextLeafGuess] }
                                else { $nextPlay = $cand }
                                $nextTitle = [System.IO.Path]::GetFileNameWithoutExtension($nextLeafGuess)
                            }
                        }
                    } catch {}
                    # Single Torbox mylist lookup for the guessed name (still only +1).
                    if (-not $nextPlay) {
                        try {
                            $one3 = Get-TorboxBulkLinks @($nextLeafGuess)
                            if ($one3.ContainsKey($nextLeafGuess)) {
                                $nextPlay = [string]$one3[$nextLeafGuess]
                                $nextTitle = [System.IO.Path]::GetFileNameWithoutExtension($nextLeafGuess)
                            }
                        } catch {}
                    }
                }
            } catch {}
        }
        if ($nextPlay) {
            if (-not $nextTitle) { $nextTitle = [System.IO.Path]::GetFileNameWithoutExtension($nextPlay.Split('?')[0]) }
            Start-Process -FilePath $wPot -ArgumentList "`"$nextPlay`"", '/add' -WindowStyle Normal -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {}
}

function New-ReliableSeasonPlaylist([string]$SelectedPath){
    try{
        $targetSource = if($script:originalTPathForHttp){ Resolve-ReliablePlaylistSource ([string]$script:originalTPathForHttp) } else { Resolve-ReliablePlaylistSource $SelectedPath }
        if([string]::IsNullOrWhiteSpace($targetSource)){ return '' }
        if($targetSource -notmatch '(?i)(season[\s._-]*\d+|s\d{1,3}e\d{1,4})' -and $SelectedPath -notmatch '(?i)(season[\s._-]*\d+|s\d{1,3}e\d{1,4})'){ return '' }

        $localCandidates = @(Get-ReliablePlaylistLocalCandidates $targetSource)
        $remoteCandidates = @(Get-ReliablePlaylistRemoteCandidates $targetSource)
        $allCandidates = [System.Collections.Generic.List[object]]::new()
        foreach($candidate in $localCandidates){ [void]$allCandidates.Add($candidate) }
        foreach($candidate in $remoteCandidates){ [void]$allCandidates.Add($candidate) }
        $proxyAvailable = Test-ReliablePlaylistProxy
        $jellyfinCandidates = @()
        if($allCandidates.Count -lt 2 -or -not $proxyAvailable){
            $jellyfinCandidates = @(Get-ReliablePlaylistJellyfinCandidates ([string]$itemId) $serverUrl ([string]$userId) ([string]$token))
            foreach($candidate in $jellyfinCandidates){ [void]$allCandidates.Add($candidate) }
        }

        $targetName = [System.IO.Path]::GetFileName($targetSource)
        if([string]::IsNullOrWhiteSpace($targetName)){ $targetName = [System.IO.Path]::GetFileName($SelectedPath) }
        [void]$allCandidates.Add([PSCustomObject]@{
            Name = $targetName
            SourcePath = $targetSource
            OriginalPath = $SelectedPath
            JellyfinItemId = [string]$itemId
            Tier = 'target'
        })

        $seenSources = @{}
        $uniqueCandidates = [System.Collections.Generic.List[object]]::new()
        foreach($candidate in $allCandidates){
            $source = Resolve-ReliablePlaylistSource ([string]$candidate.SourcePath)
            if([string]::IsNullOrWhiteSpace($source) -or $source -match '\.strm$'){ continue }
            $sourceKey = $source.ToLowerInvariant()
            if(-not $seenSources.ContainsKey($sourceKey)){
                $seenSources[$sourceKey] = $uniqueCandidates.Count
                [void]$uniqueCandidates.Add($candidate)
            } else {
                # Keep Jellyfin metadata when a remote listing found the same path first.
                # The item id is needed for Jellyfin streaming if the local proxy is unavailable.
                $existing = $uniqueCandidates[[int]$seenSources[$sourceKey]]
                if([string]::IsNullOrWhiteSpace([string]$existing.JellyfinItemId) -and -not [string]::IsNullOrWhiteSpace([string]$candidate.JellyfinItemId)){
                    $existing.JellyfinItemId = [string]$candidate.JellyfinItemId
                }
                try{
                    $candIdx = $null
                    try{ $candIdx = $candidate.JellyfinIndexNumber }catch{}
                    $existIdx = $null
                    try{ $existIdx = $existing.JellyfinIndexNumber }catch{}
                    if($null -eq $existIdx -and $null -ne $candIdx){
                        if($existing.PSObject.Properties['JellyfinIndexNumber']){ $existing.JellyfinIndexNumber = $candIdx }
                        else { $existing | Add-Member -NotePropertyName 'JellyfinIndexNumber' -NotePropertyValue $candIdx -Force }
                    }
                    $candParentIdx = $null
                    try{ $candParentIdx = $candidate.JellyfinParentIndexNumber }catch{}
                    $existParentIdx = $null
                    try{ $existParentIdx = $existing.JellyfinParentIndexNumber }catch{}
                    if($null -eq $existParentIdx -and $null -ne $candParentIdx){
                        if($existing.PSObject.Properties['JellyfinParentIndexNumber']){ $existing.JellyfinParentIndexNumber = $candParentIdx }
                        else { $existing | Add-Member -NotePropertyName 'JellyfinParentIndexNumber' -NotePropertyValue $candParentIdx -Force }
                    }
                }catch{}
                if(([string]$existing.OriginalPath -match '\.strm$') -and ([string]$candidate.OriginalPath -notmatch '\.strm$')){
                    $existing.OriginalPath = [string]$candidate.OriginalPath
                }
            }
        }

        $torboxLinks = @{}
        $torboxNames = @($uniqueCandidates | ForEach-Object {
            $source = Resolve-ReliablePlaylistSource ([string]$_.SourcePath)
            if($source -match '^T:\\'){ [System.IO.Path]::GetFileName($source) }
        } | Where-Object { $_ } | Sort-Object -Unique)
        if($torboxNames.Count -gt 0){
            try{ $torboxLinks = Get-TorboxBulkLinks $torboxNames }catch{ Write-BridgeLog "PLAYLIST tier 2 Torbox link resolution failed: $_" }
        }

        $resolved = [System.Collections.Generic.List[object]]::new()
        $seenPlayPaths = @{}
        foreach($candidate in $uniqueCandidates){
            $playPath = Resolve-ReliablePlaylistEntry $candidate $torboxLinks $proxyAvailable $serverUrl ([string]$token)
            if(-not (Test-ReliablePlaylistOutput $playPath)){ continue }
            $playKey = $playPath.ToLowerInvariant()
            if($seenPlayPaths.ContainsKey($playKey)){ continue }
            $seenPlayPaths[$playKey] = $true
            $candIdx = $null
            try{ $candIdx = $candidate.JellyfinIndexNumber }catch{}
            $candParentIdx = $null
            try{ $candParentIdx = $candidate.JellyfinParentIndexNumber }catch{}
            [void]$resolved.Add([PSCustomObject]@{
                Name = [System.IO.Path]::GetFileNameWithoutExtension([string]$candidate.Name)
                SourcePath = Resolve-ReliablePlaylistSource ([string]$candidate.SourcePath)
                PlayPath = $playPath
                Tier = [string]$candidate.Tier
                JellyfinIndexNumber = $candIdx
                JellyfinParentIndexNumber = $candParentIdx
            })
        }

        $indexKnownCount = 0
        try{ $indexKnownCount = @($resolved | Where-Object { $null -ne $_.JellyfinIndexNumber }).Count }catch{ $indexKnownCount = 0 }
        $orderSource = 'filename'
        if($indexKnownCount -gt 0){ $orderSource = 'indexnumber' }
        $ordered = @($resolved | Sort-Object @{Expression={
            $fileNum = 999999
            try{ if([string]$_.Name -match '(?i)(?:s\d{1,3})?e(\d{1,4})'){ $fileNum = [int]$Matches[1] } }catch{}
            $orderKey = $fileNum
            try{
                if($null -ne $_.JellyfinIndexNumber){ $orderKey = [int]$_.JellyfinIndexNumber }
                elseif($null -ne $_.JellyfinParentIndexNumber){ $orderKey = [int]$_.JellyfinParentIndexNumber }
            }catch{}
            $orderKey
        }}, @{Expression={
            $fileNum2 = 999999
            try{ if([string]$_.Name -match '(?i)(?:s\d{1,3})?e(\d{1,4})'){ $fileNum2 = [int]$Matches[1] } }catch{}
            $fileNum2
        }}, Name)
        try{ Write-BridgeLog "PLAYLIST order=$orderSource (indexnumber=$indexKnownCount/$($resolved.Count))" }catch{}
        $targetKey = $targetSource.ToLowerInvariant()
        $targetLeaf = [System.IO.Path]::GetFileName($targetSource).ToLowerInvariant()
        $targetIndex = -1
        for($i = 0; $i -lt $ordered.Count; $i++){
            if(([string]$ordered[$i].SourcePath).ToLowerInvariant() -eq $targetKey -or
               ([string]$ordered[$i].SourcePath -and [System.IO.Path]::GetFileName([string]$ordered[$i].SourcePath).ToLowerInvariant() -eq $targetLeaf)){
                $targetIndex = $i
                break
            }
        }

        # Tier 4: recover only the selected item when every season listing is unavailable.
        if($targetIndex -lt 0 -and $targetSource -match '^T:\\'){
            $fallbackTarget = Get-FullCacheFallbackPath $targetSource ([string]$itemId)
            if($fallbackTarget -and (Test-ReliablePlaylistOutput $fallbackTarget)){
                [void]$resolved.Add([PSCustomObject]@{ Name = [System.IO.Path]::GetFileNameWithoutExtension($targetName); SourcePath = $targetSource; PlayPath = $fallbackTarget; Tier = 'target-cache' })
                $ordered = @($resolved)
                $targetIndex = $ordered.Count - 1
            }
        }
        if($targetIndex -lt 0){
            Write-BridgeLog "PLAYLIST: refusing launch because the selected episode was not resolved to a valid entry."
            return ''
        }
        $identity = $targetSource + '|' + $targetName
        $playlistPath = Write-ReliablePlaylistFile $ordered $targetIndex $identity
        if($playlistPath){
            Write-BridgeLog "PLAYLIST: local=$($localCandidates.Count), rclone=$($remoteCandidates.Count), jellyfin=$($jellyfinCandidates.Count), final=$($ordered.Count), selected=$($targetIndex + 1), order=$orderSource, file=$playlistPath"
        }
        return $playlistPath
    } catch {
        Write-BridgeLog "PLAYLIST: reliable fallback chain failed: $_"
        return ''
    }
}

function Start-SelectedPotPlayer {
    param([string]$Path)

    # OPT-IN INSTANT PATH (-Single / POTPLAYER_SINGLE=1): single-entry playlist + lazy next.
    if (-not $script:FullSeasonMode) {
        try {
            $singlePlay = Resolve-SinglePlayPath $Path
            if ((-not $singlePlay) -and $Path -match '^https?://') { $singlePlay = $Path }
            if ((-not $singlePlay) -and $Path -match '^[a-zA-Z]:[\\/]' -and (Test-Path -LiteralPath $Path -PathType Leaf)) { $singlePlay = $Path }
            if ($singlePlay) {
                $nice = Get-SingleNiceTitle $Path $singlePlay
                $singleDpl = New-SinglePlaylist $singlePlay $nice ($Path + '|' + $singlePlay)
                if ($singleDpl -and (Test-Path -LiteralPath $singleDpl -PathType Leaf)) {
                    Write-BridgeLog "SINGLE: instant launch $singleDpl playname=$singlePlay title=$nice seek=$($script:resumeSec)s"
                    # Instant start: do NOT kill PotPlayer; /current replaces session.
                    $seekArgs = @()
                    if ($script:resumeSec -gt 0) { $seekArgs += '/seek=' + $script:resumeSec }
                    Start-PotPlayer -FilePath $potExe -ArgumentList (@("`"$singleDpl`"", '/current') + $seekArgs) -WindowStyle Normal | Out-Null
                    try { Start-LazyNextAppend $Path } catch {}
                    return
                }
                Write-BridgeLog "SINGLE: dpl write failed, direct launch $singlePlay"
                Start-PotPlayer -FilePath $potExe -ArgumentList "`"$singlePlay`"", '/current' -WindowStyle Normal | Out-Null
                try { Start-LazyNextAppend $Path } catch {}
                return
            }
            Write-BridgeLog "SINGLE: could not resolve selected entry, falling through to legacy path"
        } catch { Write-BridgeLog "SINGLE: instant path error $_, falling through to legacy" }
    }

    # DEFAULT: full reliable season playlist (whole series visible, as before).
    $reliablePlaylist = ''
    if ($script:FullSeasonMode) {
        $reliablePlaylist = New-ReliableSeasonPlaylist -SelectedPath $Path
    }
    if($reliablePlaylist -and (Test-Path -LiteralPath $reliablePlaylist -PathType Leaf)){
        $processNames = @('PotPlayerMini64', 'PotPlayer64', 'PotPlayer')
        Get-Process -Name $processNames -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 350
        Write-BridgeLog "PLAYLIST: launching reliable season playlist $reliablePlaylist seek=$($script:resumeSec)s"
        $seekArgs = @()
        if ($script:resumeSec -gt 0) { $seekArgs += '/seek=' + $script:resumeSec }
        Start-PotPlayer -FilePath $potExe -ArgumentList (@("`"$reliablePlaylist`"") + $seekArgs) -WindowStyle Normal | Out-Null
        return
    }

    # Global pre-flight check: if local path missing and not http, attempt final error handling
    if($Path -match '^[a-zA-Z]:[\\/]' -and -not (Test-Path -LiteralPath $Path) -and $Path -notmatch '^https?://'){
        Write-BridgeLog "Start-SelectedPotPlayer: path missing (global check): $Path"
        if($Path -match '^https?://'){
            # never hit, but keep
        } elseif($Path -match '\.strm$' -and (Test-Path -LiteralPath $Path)){
            Write-BridgeLog "Path is .strm that was not resolved earlier - attempting direct Jellyfin stream fallback"
            if($itemId -and $token){ $Path = $serverUrl.TrimEnd('/') + "/Videos/$itemId/stream?static=true&api_key=$token"; Write-BridgeLog "Fallback to $Path" } else { Show-MissingFileDialog $Path $itemId; return }
        } else {
            Show-MissingFileDialog $Path $itemId
            # If we have Jellyfin stream URL from 5c, Path would be http; otherwise abort launch to avoid PotPlayer 'File not found' dialog
            if($Path -match '^https?://'){ } else { return }
        }
    }
    # HTTP fallback: stream directly via PotPlayer (supports http progressive) — with full playlist + nice title (fix UUID title 24541d9b... bruh)
    if($Path -match '^https?://'){
        Write-BridgeLog "Launching PotPlayer with HTTP stream: $Path"
        $processNames = @('PotPlayerMini64', 'PotPlayer64', 'PotPlayer')
        Get-Process -Name $processNames -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 350
        # If this HTTP came from a T:\ CDN conversion, generate a .dpl with nice title + full 23-episode playlist (as T:\ .dpl does) so bar + playlist both nice
        try{
            $isHttpProxy = $Path -match "tb-cdn\.earth|workers\.dev|127\.0\.0\.1:8888"
            $hasOriginal = $script:originalTPathForHttp -and ($script:originalTPathForHttp -match "^[Tt]:\\" -or $script:originalTPathForHttp -match "^F:\\Media\\" -or $script:originalTPathForHttp -match "^G:\\")
            if($isHttpProxy -and $hasOriginal){
                $parentDir = Split-Path $script:originalTPathForHttp -Parent
                $parentExists = Test-Path -LiteralPath $parentDir
                # For stale T:\ where parent not visible on T:\, fallback to Torbox API for full playlist (not just 1)
                if(-not $parentExists -and $Path -match "127\.0\.0\.1:8888/torbox/"){
                    try{
                        $torrentId = ($Path -split "/torbox/")[1].Split("/")[0]
                        $fileName = Split-Path $script:originalTPathForHttp -Leaf
                        Write-BridgeLog "HTTP stale T:\ parent not visible $parentDir, building playlist via Torbox API for torrent $torrentId"
                        # Build the playlist from the Torbox torrent record itself. Do not
                        # infer file_id from rclone's path/name output: the API requires the
                        # numeric file id, while rclone returns a relative path in .Name.
                        $data = $null
                        try{ $data = Get-TorboxMylistCached } catch {}
                        $apiTorrent = $data | Where-Object { "$($_.id)" -eq "$torrentId" } | Select-Object -First 1
                        $apiFiles = @()
                        if($apiTorrent -and $apiTorrent.files){
                            $apiFiles = @($apiTorrent.files | Where-Object { $_.short_name -and "$($_.id)" -match '^\d+$' -and (Test-PlaylistMediaFileName ([string]$_.short_name)) } | Sort-Object short_name)
                        }
                        if($apiFiles.Count -gt 0){
                            $playlistDir = 'F:\Jellyfin\cache\playlists'
                            if(-not (Test-Path -LiteralPath $playlistDir)){ New-Item -ItemType Directory -Path $playlistDir -Force | Out-Null }
                            $safeHash = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($parentDir + $Path)))).Replace('-','').Substring(0,16).ToLowerInvariant()
                            $playlistPath = Join-Path $playlistDir ("potplayer-http-$safeHash.dpl")
                            $lines = [System.Collections.Generic.List[string]]::new()
                            $targetName = [System.IO.Path]::GetFileName($script:originalTPathForHttp)
                            $niceTitle = [System.IO.Path]::GetFileNameWithoutExtension([string]$script:cdnNiceTitle)
                            if(-not $niceTitle){ $niceTitle = [System.IO.Path]::GetFileNameWithoutExtension($targetName) }
                            $targetIndex = 0
                            for($i=0;$i -lt $apiFiles.Count;$i++){
                                if([string]::Equals([string]$apiFiles[$i].short_name, $targetName, [System.StringComparison]::OrdinalIgnoreCase)){ $targetIndex = $i; break }
                            }
                            $targetFile = $apiFiles[$targetIndex]
                            $targetProxy = "http://127.0.0.1:8888/torbox/$torrentId/$($targetFile.id)/$([Uri]::EscapeDataString([string]$targetFile.short_name))"
                            $lines.Add('DAUMPLAYLIST')
                            $lines.Add('playname=' + $targetProxy)
                            $lines.Add('playindex=' + $targetIndex)
                            $lines.Add('topindex=0')
                            $count = 1
                            foreach($f in $apiFiles){
                                $fname = [string]$f.short_name
                                $title = [System.IO.Path]::GetFileNameWithoutExtension($fname)
                                if([string]::Equals($fname, $targetName, [System.StringComparison]::OrdinalIgnoreCase)){ $title = $niceTitle }
                                $fpath = "http://127.0.0.1:8888/torbox/$torrentId/$($f.id)/$([Uri]::EscapeDataString($fname))"
                                $lines.Add("$count`*file`*" + $fpath)
                                $lines.Add("$count`*title`*" + $title)
                                $count++
                            }
                            [System.IO.File]::WriteAllLines($playlistPath, $lines, [System.Text.Encoding]::Unicode)
                            Write-BridgeLog "HTTP stale Torbox playlist via API full $($apiFiles.Count) with numeric file IDs: $playlistPath"
                            Start-PotPlayer -FilePath $potExe -ArgumentList "`"$playlistPath`"" -WindowStyle Normal | Out-Null
                            return
                        }
                        # Fallback: use rclone ls for torbox: parent folder
                        $relParent = $script:originalTPathForHttp.Substring(3) -replace '\\','/'
                        $folder = ($relParent -split "/")[0]
                        $rcloneExe='F:\Jellyfin\server\rclone.exe'; if(-not (Test-Path $rcloneExe)){ $rcloneExe='rclone' }
                        $lsOut = & $rcloneExe --config "F:\Jellyfin\config\rclone.conf" lsjson "torbox:$folder" 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if($lsOut){
                            $playlistDir = 'F:\Jellyfin\cache\playlists'
                            if(-not (Test-Path -LiteralPath $playlistDir)){ New-Item -ItemType Directory -Path $playlistDir -Force | Out-Null }
                            $safeHash = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($parentDir + $Path)))).Replace('-','').Substring(0,16).ToLowerInvariant()
                            $playlistPath = Join-Path $playlistDir ("potplayer-http-$safeHash.dpl")
                            $lines = [System.Collections.Generic.List[string]]::new()
                            $lines.Add('DAUMPLAYLIST')
                            $lines.Add('playname=' + $Path)
                            $lines.Add('playindex=0')
                            $lines.Add('topindex=0')
                            $niceTitle = [System.IO.Path]::GetFileNameWithoutExtension($script:cdnNiceTitle)
                            $count = 1
                             # Build from API/rclone ls (natural order so E2 < E10)
                             $sorted = $lsOut | Sort-Object { Get-NaturalSortKey $_.Name }
                            $targetName = Split-Path $script:originalTPathForHttp -Leaf
                            $targetIdx = 0
                            for($i=0;$i -lt $sorted.Count;$i++){ if($sorted[$i].Name -eq $targetName){ $targetIdx = $i; break } }
                            $lines[2] = 'playindex=' + $targetIdx
                            foreach($f in $sorted){
                                $isTarget = $f.Name -eq $targetName
                                $title = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
                                if($isTarget){ $title = $niceTitle }
                                # Build proxy URL for each
                                $fid = $null
                                # Find file id via cache
                                try{
                                    $torFiles = (get_torrent_files | Where-Object { $_.name -like "*$folder*" } | Select-Object -First 1).files
                                    $mf = $torFiles | Where-Object { $_.short_name -eq $f.Name } | Select-Object -First 1
                                    if($mf){ $fid = $mf.id; $tid = $torrentId }
                                } catch {}
                                $fpath = $null
                                if($isTarget){ $fpath = $Path }
                                else {
                                    # Try to get proxy for sibling via bulk
                                    try{
                                        $bulk = Get-TorboxBulkLinks @($f.Name)
                                        if($bulk.ContainsKey($f.Name)){ $fpath = $bulk[$f.Name] }
                                        elseif("$fid" -match '^\d+$'){ $fpath = "http://127.0.0.1:8888/torbox/$torrentId/$fid/" + [Uri]::EscapeDataString($f.Name) }
                                        else { $fpath = $null; Write-BridgeLog "Skipping playlist sibling without numeric Torbox file id: $($f.Name)" }
                                    } catch { $fpath = $null }
                                    if($fpath -and $fpath -notmatch "^https?://"){ $fpath = $null }
                                }
                                $lines.Add("$count`*file`*" + $fpath)
                                $lines.Add("$count`*title`*" + $title)
                                $count++
                            }
                            [System.IO.File]::WriteAllLines($playlistPath, $lines, [System.Text.Encoding]::Unicode)
                            Write-BridgeLog "HTTP stale Torbox playlist via API full $($sorted.Count) http: $playlistPath"
                            Start-PotPlayer -FilePath $potExe -ArgumentList "`"$playlistPath`"" -WindowStyle Normal | Out-Null
                            return
                        }
                    } catch { Write-BridgeLog "HTTP stale API playlist fail $_" }
                }
                if(-not (Test-Path -LiteralPath $parentDir)){
                    # No T:\ parent and not handled above, fallback to single HTTP
                    Write-BridgeLog "HTTP stale parent not visible and no API, launching single $Path"
                    Start-PotPlayer -FilePath $potExe -ArgumentList "`"$Path`"", '/current', '/play' -WindowStyle Normal | Out-Null
                    return
                }
                $niceFileName = if($script:cdnNiceTitle){ $script:cdnNiceTitle } else { [System.IO.Path]::GetFileName($Path).Split('?')[0] }
                $niceTitle = [System.IO.Path]::GetFileNameWithoutExtension($niceFileName)
                # Sanitize title for PotPlayer
                if(-not $niceTitle -or $niceTitle -match "^[a-f0-9\-]{30,}"){ $niceTitle = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path $script:originalTPathForHttp -Leaf)) }
                $extensions = @('.mkv', '.mp4', '.avi', '.ts', '.m4v', '.mov', '.webm', '.flv', '.wmv', '.m2ts')
                $allFiles = @(Get-ChildItem -LiteralPath $parentDir -File -ErrorAction SilentlyContinue | Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } | Sort-Object Name)
                # HTTP stale fallback: T:\ parent 0 files via WinFsp but rclone torbox: has 12-23 (Desperate 23, Dexter NOGRP 12) — use rclone lsjson for playlist not 1
                if($allFiles.Count -le 1){
                    try{
                        $relParentHttp2 = $script:originalTPathForHttp.Substring(3) -replace '\\','/'
                        if($script:originalTPathForHttp -match "^F:\\Media\\"){ $relParentHttp2 = $script:originalTPathForHttp.Substring(9) -replace '\\','/' }
                        $folderHttp2 = ($relParentHttp2 -split "/")[0]
                        $rcloneExeH2='F:\Jellyfin\server\rclone.exe'; if(-not (Test-Path $rcloneExeH2)){ $rcloneExeH2='rclone' }
                        $lsHttp2 = $null
                        # Try torbox folder (for T:\ Dexter NOGRP[rartv] etc.) — need exact folder with [rartv]
                        $torboxFolder = $folderHttp2
                        # For T:\Dexter...NOGRP[rartv]\file, folder is Dexter...NOGRP[rartv] — rclone needs exact
                        $lsHttp2 = & $rcloneExeH2 --config "F:\Jellyfin\config\rclone.conf" lsjson "torbox:$torboxFolder" 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if(-not $lsHttp2 -or $lsHttp2.Count -le 1){
                            # Fallback: try without [rartv] suffix or with different base
                            $altFolder = $folderHttp2 -replace "\[rartv\]", ""
                            $lsHttp2 = & $rcloneExeH2 --config "F:\Jellyfin\config\rclone.conf" lsjson "torbox:$altFolder" 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
                        }
                        if(-not $lsHttp2 -or $lsHttp2.Count -le 1){
                            # GDrive fallback
                            $gdriveRel = $relParentHttp2 -replace '/[^/]+$',''
                            $lsHttp2 = & $rcloneExeH2 --config "F:\Jellyfin\config\rclone.conf" lsjson "gdrive-media:$gdriveRel" 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
                        }
                        if($lsHttp2 -and ($lsHttp2 | Where-Object { -not $_.IsDir }).Count -gt 1){
                            $filtered = @($lsHttp2 | Where-Object { -not $_.IsDir } | Where-Object { $extensions -contains [System.IO.Path]::GetExtension($_.Name).ToLowerInvariant() } | Sort-Object Name)
                            if($filtered.Count -gt 1){
                                Write-BridgeLog "HTTP stale fallback via rclone $($filtered.Count) files for $parentDir (vs Get-ChildItem $($allFiles.Count)) - using rclone for universal playlist"
                                $allFiles = @($filtered | ForEach-Object {
                                    $fi = New-Object PSObject -Property @{ Name = $_.Name; FullName = Join-Path $parentDir $_.Name; Extension = [System.IO.Path]::GetExtension($_.Name); Length = $_.Size }
                                    $fi | Add-Member -NotePropertyName DirectoryName -NotePropertyValue $parentDir
                                    $fi
                                })
                            }
                        }
                    } catch { Write-BridgeLog "HTTP stale rclone fallback fail $_" }
                }
                if($allFiles.Count -gt 1){
                    $targetIndex = 0
                    for($i=0;$i -lt $allFiles.Count;$i++){
                        if($allFiles[$i].FullName.Equals($script:originalTPathForHttp, [System.StringComparison]::OrdinalIgnoreCase)){
                            $targetIndex = $i; break
                        }
                    }
                    $playlistDir = 'F:\Jellyfin\cache\playlists'
                    if(-not (Test-Path -LiteralPath $playlistDir)){ New-Item -ItemType Directory -Path $playlistDir -Force | Out-Null }
                    $safeHash = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($parentDir + $Path)))).Replace('-','').Substring(0,16).ToLowerInvariant()
                    $playlistPath = Join-Path $playlistDir ("potplayer-http-$safeHash.dpl")
                    $lines = [System.Collections.Generic.List[string]]::new()
                    $lines.Add('DAUMPLAYLIST')
                    $lines.Add('playname=' + $Path)
                    $lines.Add('playindex=' + $targetIndex)
                    $lines.Add('topindex=0')
                    # FIX: resolve ALL siblings to HTTP (not just target) so every episode has HTTP progressive bar — not scam F:\Media\...
                    $bulkNames = @($allFiles | ForEach-Object { $_.Name })
                    $cdnMap = @{}
                    # Try Torbox bulk for Torbox/Cursed via T:\/G:\ — for 127.0.0.1:8888 proxy we generate gdrive proxy for all siblings
                    if($Path -match "127\.0\.0\.1:8888/gdrive"){
                        # GDrive: every sibling via local proxy http://127.0.0.1:8888/gdrive/Series/Cursed/... (full rel from G:\ or F:\Media\)
                        $count = 1
                        foreach($file in $allFiles){
                            $isTarget = $file.FullName.Equals($script:originalTPathForHttp, [System.StringComparison]::OrdinalIgnoreCase)
                            $fname = $file.Name
                            $title = [System.IO.Path]::GetFileNameWithoutExtension($fname)
                            if($isTarget){ $title = $niceTitle }
                            # Full rel from G:\ or F:\Media\ for proxy (so /gdrive/Series/Cursed/... not just filename)
                            $fullRel = $null
                            if($file.FullName -match '^G:\\'){ $fullRel = $file.FullName.Substring(3) -replace '\\','/' }
                            elseif($file.FullName -match '^F:\\Media\\'){ $fullRel = $file.FullName.Substring(9) -replace '\\','/' }
                            else { $fullRel = $file.FullName.Substring($parentDir.Length + 1) -replace '\\','/' }
                            $httpUrl = "http://127.0.0.1:8888/gdrive/$([Uri]::EscapeDataString($fullRel).Replace('%2F','/').Replace('%5C','/'))"
                            $filePath = $httpUrl
                            if($isTarget){ $filePath = $Path } # keep original target's exact proxy URL
                            $lines.Add("$count`*file`*" + $filePath)
                            $lines.Add("$count`*title`*" + $title)
                            $count++
                        }
                        [System.IO.File]::WriteAllLines($playlistPath, $lines, [System.Text.Encoding]::Unicode)
                        Write-BridgeLog "HTTP GDrive playlist full $($allFiles.Count) http via 127.0.0.1:8888/gdrive: $playlistPath"
                        Start-PotPlayer -FilePath $potExe -ArgumentList "`"$playlistPath`"" -WindowStyle Normal | Out-Null
                        return
                    } else {
                        $cdnMap = Get-TorboxBulkLinks $bulkNames
                    }
                    $count = 1
                    foreach($file in $allFiles){
                        $isTarget = $file.FullName.Equals($script:originalTPathForHttp, [System.StringComparison]::OrdinalIgnoreCase)
                        $fname = $file.Name
                        $title = [System.IO.Path]::GetFileNameWithoutExtension($fname)
                        if($isTarget){ $title = $niceTitle }
                        $filePath = $null
                        if($isTarget){ $filePath = $Path }
                        elseif($cdnMap.ContainsKey($fname) -and $cdnMap[$fname] -match "^https?://"){ $filePath = $cdnMap[$fname] }
                        else {
                            # Fallback for torbox without bulk: try to generate proxy for this file via single Get-TorboxDirectLinkViaApi if not in bulk (to avoid scam T:\)
                            try{
                                $singleCdn = Get-TorboxDirectLinkViaApi $file.FullName
                                if($singleCdn -and $singleCdn -match "^https?://"){ $filePath = $singleCdn } else { $filePath = $file.FullName }
                            } catch { $filePath = $file.FullName }
                        }
                        $lines.Add("$count`*file`*" + $filePath)
                        $lines.Add("$count`*title`*" + $title)
                        $count++
                    }
                    [System.IO.File]::WriteAllLines($playlistPath, $lines, [System.Text.Encoding]::Unicode)
                    $httpCount = @($cdnMap.Values | Where-Object { $_ -match "^https?://" }).Count + 1
                    Write-BridgeLog "HTTP playlist with nice title + full $($allFiles.Count) episodes ($httpCount http, rest T:\ fallback): $playlistPath (playname $niceTitle)"
                    Start-PotPlayer -FilePath $potExe -ArgumentList "`"$playlistPath`"" -WindowStyle Normal | Out-Null
                    return
                } else {
                    # Single file HTTP with nice title via temp playlist
                    $playlistDir = 'F:\Jellyfin\cache\playlists'
                    if(-not (Test-Path $playlistDir)){ New-Item -ItemType Directory -Path $playlistDir -Force | Out-Null }
                    $safeHash = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Path)))).Replace('-','').Substring(0,16).ToLowerInvariant()
                    $playlistPath = Join-Path $playlistDir ("potplayer-http-$safeHash.dpl")
                    $lines = [System.Collections.Generic.List[string]]::new()
                    $lines.Add('DAUMPLAYLIST')
                    $lines.Add('playname=' + $Path)
                    $lines.Add('playindex=0')
                    $lines.Add('topindex=0')
                    $lines.Add("1*file*$Path")
                    $lines.Add("1*title*$niceTitle")
                    [System.IO.File]::WriteAllLines($playlistPath, $lines, [System.Text.Encoding]::Unicode)
                    Write-BridgeLog "HTTP single with nice title $niceTitle -> $playlistPath"
                    Start-PotPlayer -FilePath $potExe -ArgumentList "`"$playlistPath`"" -WindowStyle Normal | Out-Null
                    return
                }
            }
        } catch { Write-BridgeLog "HTTP playlist nice-title error: $_" }
        Start-PotPlayer -FilePath $potExe -ArgumentList "`"$Path`"", '/current', '/play' -WindowStyle Normal | Out-Null
        return
    }

    $processNames = @('PotPlayerMini64', 'PotPlayer64', 'PotPlayer')
    Get-Process -Name $processNames -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 350

    $playlistPath = $null
    if (($Path -match '^[a-zA-Z]:[\\/]') -and (Test-Path -LiteralPath $Path)) {
        try {
            $item = Get-Item -LiteralPath $Path -ErrorAction Stop
            if ($item -is [System.IO.FileInfo]) {
                $parentDir = $item.DirectoryName
                
                # Check path length: if parent directory or full path is long (>200 chars),
                # map a virtual drive (Y:) to parent directory to guarantee PotPlayer & DirectShow render successfully
                $useVirtualDrive = $false
                $virtualDrive = "Y:"
                if ($Path.Length -ge 180 -or $parentDir.Length -ge 120) {
                    try {
                        cmd.exe /c "subst $virtualDrive /D" 2>$null | Out-Null
                        cmd.exe /c "subst $virtualDrive `"$parentDir`"" 2>$null | Out-Null
                        if (Test-Path "$virtualDrive\") {
                            $useVirtualDrive = $true
                        }
                    } catch {}
                }

                $extensions = @('.mkv', '.mp4', '.avi', '.ts', '.m4v', '.mov', '.webm', '.flv', '.wmv', '.m2ts')
                $allFiles = @(Get-ChildItem -LiteralPath $parentDir -File -ErrorAction SilentlyContinue |
                    Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
                    Sort-Object { Get-NaturalSortKey $_.Name })
                # FIX: stale T:\ returns 0 via WinFsp but rclone torbox: has 23 (Desperate 13:31 C 0 vs rclone 23) — fallback to rclone lsjson so playlist not just 1
                # UNIVERSAL: also handle variant picker where parent is T:\Dexter...NOGRP[rartv] but rclone folder is Dexter.S08...NOGRP[rartv] vs Dexter S08...Mesc — and ensure all episodes of that title/season are included, not just folder
                if ($allFiles.Count -le 1 -and $Path -match '^[Tt]:\\') {
                    try{
                        $relParentStale = $Path.Substring(3) -replace '\\','/'
                        $folderStale = ($relParentStale -split "/")[0]
                        $rcloneExe2='F:\Jellyfin\server\rclone.exe'; if(-not (Test-Path $rcloneExe2)){ $rcloneExe2='rclone' }
                        $lsOutStale = & $rcloneExe2 --config "F:\Jellyfin\config\rclone.conf" lsjson "torbox:$folderStale" 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if(-not $lsOutStale -or $lsOutStale.Count -le 1){
                            # Try alternative folder name without [rartv] or with different prefix — also try show/season filter across all torbox folders
                            # Universal filter: find all torbox folders that contain Dexter S08 etc., and collect matching episode files
                            $showSeason = ""
                            if($Path -match "(Dexter|Cursed|Desperate|Adolescence)[^0-9]*S0*(\d+)E0*(\d+)" -or $Path -match "([A-Za-z0-9\.\s]+)S0*(\d+)E0*(\d+)"){
                                $showRaw = $Matches[1] -replace "[\.\s]+"," " -replace "^\s+|\s+$",""
                                $seasonNum = $Matches[2]
                                # Search all torbox folders for matching show/season via variants.json or rclone lsf
                                try{
                                    $variantsJson = Get-Content "F:\Jellyfin\server\jellyfin-web\variants.json" -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                                    if($variantsJson){
                                        # Find all variants for this show/season via catalog keys like "Dexter|08|01"
                                        $allKeys = $variantsJson.PSObject.Properties.Name
                                        $matching = @()
                                        foreach($k in $allKeys){
                                            if($k -like "*$showRaw*" -or $k -match [regex]::Escape($showRaw.Split(" ")[0])){
                                                $matching += $variantsJson.$k
                                            }
                                        }
                                        # Also directly collect from torbox: list all folders and filter
                                        $allFolders = & $rcloneExe2 --config "F:\Jellyfin\config\rclone.conf" lsf "torbox:" 2>$null | Out-String -Width 2000 | ConvertFrom-String -ErrorAction SilentlyContinue
                                    }
                                } catch {}
                            }
                            # Fallback: try rclone ls on torbox: with filter for Dexter S08
                            $lsAll = & $rcloneExe2 --config "F:\Jellyfin\config\rclone.conf" lsjson "torbox:" 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
                            if($lsAll){
                                foreach($fld in $lsAll | Where-Object { $_.IsDir }){
                                    if($fld.Name -like "*Dexter*" -and $fld.Name -like "*S08*"){
                                        $sub = & $rcloneExe2 --config "F:\Jellyfin\config\rclone.conf" lsjson "torbox:$($fld.Name)" 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
                                        if($sub -and $sub.Count -gt 1){ $lsOutStale = $sub; break }
                                    }
                                }
                            }
                        }
                        if($lsOutStale -and $lsOutStale.Count -gt 1){
                            Write-BridgeLog "T:\ stale/universal fallback via rclone lsjson torbox:$folderStale -> $($lsOutStale.Count) files (vs Get-ChildItem $($allFiles.Count))"
                            # Build FileInfo-like objects from rclone lsjson for playlist
                            $allFiles = @($lsOutStale | Where-Object { -not $_.IsDir } | Sort-Object Name | ForEach-Object {
                                $fi = New-Object PSObject -Property @{
                                    Name = $_.Name
                                    FullName = Join-Path $parentDir $_.Name
                                    Extension = [System.IO.Path]::GetExtension($_.Name)
                                    Length = $_.Size
                                }
                                # Add DirectoryName for consistency
                                $fi | Add-Member -NotePropertyName DirectoryName -NotePropertyValue $parentDir
                                $fi
                            } | Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() })
                        }
                    } catch { Write-BridgeLog "T:\ stale rclone fallback fail $_" }
                }

                if ($allFiles.Count -gt 1) {
                    $targetIndex = 0
                    for ($i = 0; $i -lt $allFiles.Count; $i++) {
                        if ($allFiles[$i].FullName.Equals($Path, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $targetIndex = $i
                            break
                        }
                    }

                    $playlistDir = 'F:\Jellyfin\cache\playlists'
                    if (-not (Test-Path -LiteralPath $playlistDir)) {
                        New-Item -ItemType Directory -Path $playlistDir -Force | Out-Null
                    }
                    $safeHash = ([System.BitConverter]::ToString(
                        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                            [System.Text.Encoding]::UTF8.GetBytes($parentDir)))).Replace('-', '').Substring(0, 16).ToLowerInvariant()
                    $playlistPath = Join-Path $playlistDir ('potplayer-' + $safeHash + '.dpl')
                    
                    $lines = [System.Collections.Generic.List[string]]::new()
                    $lines.Add('DAUMPLAYLIST')
                    
                    $activeTargetPlayname = if ($useVirtualDrive) { "$virtualDrive\" + $item.Name } else { $Path }
                    $lines.Add('playname=' + $activeTargetPlayname)
                    $lines.Add('playindex=' + $targetIndex)
                    $lines.Add('topindex=0')
                    
                    # RELIABILITY: Try bulk CDN for T:\ siblings too — gives HTTP bar even when initial play was T:\ (user complained ep2 fell back to T:\, no bar)
                    $cdnMapT = @{}
                    try{
                        $namesT = @($allFiles | ForEach-Object { $_.Name })
                        $cdnMapT = Get-TorboxBulkLinks $namesT
                        if($cdnMapT.Count -gt 0){ Write-BridgeLog "T:\ playlist bulk CDN resolved $($cdnMapT.Count)/$($allFiles.Count) to HTTP" }
                    }catch{ Write-BridgeLog "T:\ bulk CDN error: $_" }
                    $count = 1
                    foreach ($file in $allFiles) {
                        $fnameT = $file.Name
                        $titleT = [System.IO.Path]::GetFileNameWithoutExtension($fnameT)
                        $isTargetFile = $file.FullName.Equals($Path, [System.StringComparison]::OrdinalIgnoreCase)
                        # Prefer HTTP CDN when available for every file (reliable bar), otherwise fallback to file path (with virtual drive handling)
                        $filePath = if($cdnMapT.ContainsKey($fnameT) -and $cdnMapT[$fnameT] -match "^https?://"){ $cdnMapT[$fnameT] } else { if ($useVirtualDrive) { "$virtualDrive\" + $file.Name } else { $file.FullName } }
                        # If target and we already verified HEAD ok earlier, ensure target stays HTTP if it was HTTP-converted (already in cdnMapT)
                        $lines.Add("$count`*file`*" + $filePath)
                        $lines.Add("$count`*title`*" + $titleT)
                        $count++
                    }
                    [System.IO.File]::WriteAllLines($playlistPath, $lines, [System.Text.Encoding]::Unicode)
                }
            }
        } catch {
            $playlistPath = $null
        }
    }

    if ($playlistPath) {
        Start-PotPlayer -FilePath $potExe -ArgumentList "`"$playlistPath`"" -WindowStyle Normal | Out-Null
    } else {
        Start-PotPlayer -FilePath $potExe -ArgumentList "`"$Path`"", '/current', '/play' -WindowStyle Normal | Out-Null
    }
}

# Always replace the current player session with the selected release folder.
# Guarded: dot-sourcing for parser verification must not launch playback.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $tlMs = [int]$script:LaunchStopwatch.Elapsed.TotalMilliseconds
        $tlMode = 'fullseason'
        if (-not $script:FullSeasonMode) { $tlMode = 'single' }
        $tlResume = 0
        try { if ($script:resumeSec -gt 0) { $tlResume = [int]$script:resumeSec } } catch {}
        Write-BridgeLog "TELEMETRY launch total_ms=$tlMs mode=$tlMode resume=${tlResume}s media=$mediaPath"
    } catch {}
    if ($WhatIf) {
        Write-BridgeLog "WHATIF: would launch mediaPath=$mediaPath itemId=$itemId fullSeason=$($script:FullSeasonMode)"
        Write-Output "WhatIf: mediaPath=$mediaPath"
        Write-Output "WhatIf: itemId=$itemId fullSeason=$($script:FullSeasonMode)"
    } else {
        Start-SelectedPotPlayer -Path $mediaPath
    }
}
