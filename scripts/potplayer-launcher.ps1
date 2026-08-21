param(
    [Parameter(Position=0, ValueFromRemainingArguments=$true)]
    [string[]]$rawArgs
)

# Combine any split arguments if Windows passes unquoted spaces
$inputUri = ($rawArgs -join ' ').Trim()
if (-not $inputUri) { exit }

# 1. Clean protocol prefix
$target = $inputUri -replace '^potplayer://', '' -replace '^"potplayer://', '' -replace '^''potplayer://', ''

# 2. URL decode
$target = [System.Uri]::UnescapeDataString($target)
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

# 4. Handle Drive letter mappings (R:\ -> F:\Media\)
if ($mediaPath.StartsWith('R:\', [System.StringComparison]::OrdinalIgnoreCase)) {
    $mediaPath = 'F:\Media\' + $mediaPath.Substring(3)
} elseif ($mediaPath.StartsWith('R:/', [System.StringComparison]::OrdinalIgnoreCase)) {
    $mediaPath = 'F:/Media/' + $mediaPath.Substring(3)
}

# 5. Normalize path slashes for Windows
if ($mediaPath -match '^[a-zA-Z]:') {
    $mediaPath = $mediaPath -replace '/', '\'
}

$potExe = 'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe'
if (-not (Test-Path -LiteralPath $potExe)) {
    $altPot = 'C:\Program Files (x86)\DAUM\PotPlayer\PotPlayerMini64.exe'
    if (Test-Path -LiteralPath $altPot) { $potExe = $altPot }
}

# 6. Launch background playback sync tracker if credentials/itemId provided
if ($itemId -and $userId -and $token) {
    $trackerScript = 'F:\Jellyfin\potplayer-sync-tracker.ps1'
    if (Test-Path -LiteralPath $trackerScript) {
        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", "`"$trackerScript`"", "-MediaPath", "`"$mediaPath`"", "-ItemId", "`"$itemId`"", "-UserId", "`"$userId`"", "-Token", "`"$token`"", "-ServerUrl", "`"$serverUrl`""
    }
}

# 7. If local media file exists, generate complete season playlist
if (Test-Path -LiteralPath $mediaPath) {
    try {
        $item = Get-Item -LiteralPath $mediaPath -ErrorAction Stop
        if ($item -is [System.IO.FileInfo]) {
            $parentFolder = $item.DirectoryName
            $extensions = @('.mkv', '.mp4', '.avi', '.ts', '.m4v', '.mov', '.webm', '.flv', '.wmv', '.m2ts')
            
            $allFiles = Get-ChildItem -LiteralPath $parentFolder -File -ErrorAction SilentlyContinue | 
                        Where-Object { $extensions -contains $_.Extension.ToLower() } | 
                        Sort-Object Name

            if ($allFiles -and $allFiles.Count -gt 1) {
                $targetIndex = 0
                for ($i = 0; $i -lt $allFiles.Count; $i++) {
                    if ($allFiles[$i].FullName.Equals($mediaPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $targetIndex = $i
                        break
                    }
                }

                $dplFolder = 'F:\Jellyfin\cache\playlists'
                if (-not (Test-Path -LiteralPath $dplFolder)) {
                    New-Item -ItemType Directory -Path $dplFolder -Force | Out-Null
                }
                $dplPath = Join-Path $dplFolder 'season_playlist.dpl'

                $dplLines = [System.Collections.Generic.List[string]]::new()
                $dplLines.Add("DAUMPLAYLIST")
                $dplLines.Add("playname=" + $mediaPath)
                $dplLines.Add("playindex=" + $targetIndex)
                $dplLines.Add("topindex=0")

                $count = 1
                foreach ($file in $allFiles) {
                    $dplLines.Add("$count`*file`*" + $file.FullName)
                    $cleanTitle = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                    $dplLines.Add("$count`*title`*" + $cleanTitle)
                    $count++
                }

                [System.IO.File]::WriteAllLines($dplPath, $dplLines, [System.Text.Encoding]::Unicode)

                Start-Process -FilePath $potExe -ArgumentList "`"$dplPath`""
                exit
            }
        }
    } catch {
        # Fall through to direct launch
    }
}

# 8. Fallback direct playback
Start-Process -FilePath $potExe -ArgumentList "`"$mediaPath`"", "/current", "/play"
