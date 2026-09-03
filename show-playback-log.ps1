param(
    [string]$EpisodeHint = "",
    [string]$ItemId = ""
)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Hint shown in title + red highlight. Fall back to ItemId when hint is empty.
$script:hint = $EpisodeHint.Trim()
if ([string]::IsNullOrWhiteSpace($script:hint)) { $script:hint = $ItemId.Trim() }
$script:itemId = $ItemId.Trim()

# ---- Singleton: Global\PotPlayerWatchLogs, second instance takes over ----
$script:mutex = $null
$script:exitEvent = $null
function Get-ExitEvent([bool]$createIfMissing) {
    try { return [System.Threading.EventWaitHandle]::OpenExisting("Global\PotPlayerWatchLogs_Exit") }
    catch {
        if (-not $createIfMissing) { return $null }
        try {
            [bool]$created = $false
            return New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, "Global\PotPlayerWatchLogs_Exit", [ref]$created)
        } catch { return $null }
    }
}
try { $script:mutex = New-Object System.Threading.Mutex($false, "Global\PotPlayerWatchLogs") }
catch { $script:mutex = $null }
$script:ownsMutex = $false
if ($script:mutex -ne $null) {
    try { $script:ownsMutex = $script:mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $script:ownsMutex = $true }
    catch { $script:ownsMutex = $false }
    if (-not $script:ownsMutex) {
        # Signal the old window to close, then wait for it to release the mutex.
        try { $oldEvt = Get-ExitEvent $false; if ($oldEvt -ne $null) { [void]$oldEvt.Set(); $oldEvt.Close() } } catch { }
        try { $script:ownsMutex = $script:mutex.WaitOne(3500) }
        catch [System.Threading.AbandonedMutexException] { $script:ownsMutex = $true }
        catch { $script:ownsMutex = $false }
        # Even if the old window is stuck we still take over visually; old closes on next tick.
    }
}
# This instance's exit signal (non-signaled). Reset AFTER signalling old so old sees Set().
try {
    $script:exitEvent = Get-ExitEvent $true
    if ($script:exitEvent -ne $null -and $script:ownsMutex) { [void]$script:exitEvent.Reset() }
} catch { }

$logDir = "F:\Jellyfin\logs"
$launcherLog = Join-Path $logDir "potplayer-launcher.log"
$proxyLog = Join-Path $logDir "torbox-proxy.log"
$bridgeLog = Join-Path $logDir "potplayer-bridge.log"

# Fast tail: reads only last MaxBytes with shared ReadWrite access (logs may be locked for writing).
function Get-LogTail {
    param([string]$Path, [int]$Count = 25, [int]$MaxBytes = 32768)
    try {
        if (-not [System.IO.File]::Exists($Path)) { return @("(no log yet)") }
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $len = $fs.Length
            if ($len -le 0) { return @() }
            $toRead = [System.Math]::Min([long]$MaxBytes, $len)
            [void]$fs.Seek(-$toRead, [System.IO.SeekOrigin]::End)
            $buf = New-Object byte[] $toRead
            $read = 0
            while ($read -lt $toRead) {
                $n = $fs.Read($buf, $read, ($toRead - $read))
                if ($n -le 0) { break }
                $read += $n
            }
            $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
            if ([string]::IsNullOrEmpty($text)) { return @() }
            $lines = $text -split "`r?`n"
            if ($len -gt $MaxBytes -and $lines.Count -gt 1) { $lines = $lines[1..($lines.Count - 1)] }
            $out = @()
            foreach ($l in $lines) { if ($l -ne "") { $out += $l } }
            if ($out.Count -gt $Count) { $out = $out[($out.Count - $Count)..($out.Count - 1)] }
            return $out
        } finally { $fs.Close() }
    } catch { return @() }
}

function Test-PotPlayerRunning {
    try {
        $p = Get-Process -Name "PotPlayerMini64","PotPlayer64","PotPlayer" -ErrorAction SilentlyContinue
        return ($null -ne $p)
    } catch { return $false }
}

$form = New-Object System.Windows.Forms.Form
$form.Size = New-Object System.Drawing.Size(1000, 700)
$form.StartPosition = "CenterScreen"
$form.Topmost = $true
$rtb = New-Object System.Windows.Forms.RichTextBox
$rtb.Dock = "Fill"
$rtb.ReadOnly = $true
$rtb.WordWrap = $false
$rtb.ScrollBars = "Both"
$rtb.HideSelection = $false
$rtb.Font = New-Object System.Drawing.Font("Consolas", 9)
$rtb.BackColor = [System.Drawing.Color]::FromArgb(12, 12, 12)
$rtb.ForeColor = [System.Drawing.Color]::LightGray
$form.Controls.Add($rtb)

$script:lastSeen = Get-Date
$script:redRx = New-Object System.Text.RegularExpressions.Regex("(ERROR|502|429|416)", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:greenRx = New-Object System.Text.RegularExpressions.Regex("(206|Playing|HIT)", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:defaultColor = [System.Drawing.Color]::LightGray
$script:redColor = [System.Drawing.Color]::FromArgb(255, 107, 107)
$script:greenColor = [System.Drawing.Color]::FromArgb(105, 255, 150)
$script:headerColor = [System.Drawing.Color]::FromArgb(255, 220, 100)

function Add-ColorLine([string]$line, [System.Drawing.Color]$color) {
    $rtb.SelectionStart = $rtb.TextLength
    $rtb.SelectionLength = 0
    $rtb.SelectionColor = $color
    $rtb.AppendText($line + "`r`n")
}

function Update-View {
    $rtb.SuspendLayout()
    $rtb.Clear()
    $sections = @(
        @{ Name = "potplayer-launcher.log"; Path = $launcherLog },
        @{ Name = "torbox-proxy.log"; Path = $proxyLog },
        @{ Name = "potplayer-bridge.log"; Path = $bridgeLog }
    )
    foreach ($s in $sections) {
        Add-ColorLine ("=== " + $s.Name + " (last 25) ===") $script:headerColor
        $lines = @(Get-LogTail -Path $s.Path -Count 25)
        if ($lines.Count -eq 0) { $lines = @("(empty)") }
        foreach ($line in $lines) {
            $c = $script:defaultColor
            $isRed = $false
            if ($script:redRx.IsMatch($line)) { $isRed = $true }
            if (-not $isRed -and -not [string]::IsNullOrWhiteSpace($script:hint) -and $line.IndexOf($script:hint, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $isRed = $true }
            if (-not $isRed -and -not [string]::IsNullOrWhiteSpace($script:itemId) -and $line.IndexOf($script:itemId, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $isRed = $true }
            if ($isRed) { $c = $script:redColor }
            elseif ($script:greenRx.IsMatch($line)) { $c = $script:greenColor }
            Add-ColorLine $line $c
        }
        Add-ColorLine "" $script:defaultColor
    }
    $rtb.SelectionStart = $rtb.TextLength
    $rtb.ScrollToCaret()
    $rtb.ResumeLayout()
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try {
        # Takeover: if a newer instance signalled us, close so it can own the mutex.
        try {
            if ($script:exitEvent -ne $null -and $script:exitEvent.WaitOne(0)) { $form.Close(); return }
        } catch { }
        if (Test-PotPlayerRunning) {
            $script:lastSeen = Get-Date
            if ([string]::IsNullOrWhiteSpace($script:hint)) { $form.Text = "WATCHING - LIVE" }
            else { $form.Text = "WATCHING: " + $script:hint + " - LIVE" }
        } else {
            $idleSec = [int]((Get-Date) - $script:lastSeen).TotalSeconds
            $left = 60 - $idleSec
            if ($left -lt 0) { $left = 0 }
            if ([string]::IsNullOrWhiteSpace($script:hint)) { $form.Text = "PotPlayer idle - closing in " + $left + "s..." }
            else { $form.Text = "WATCHING: " + $script:hint + " - idle, closing in " + $left + "s..." }
            if ($idleSec -ge 60) { $form.Close(); return }
        }
        Update-View
    } catch { }
})
$form.Add_Shown({ Update-View; $rtb.Focus() })
$form.Add_FormClosed({
    try { $timer.Stop() } catch { }
    try { if ($script:mutex -ne $null -and $script:ownsMutex) { $script:mutex.ReleaseMutex() } } catch { }
    try { if ($script:mutex -ne $null) { $script:mutex.Close() } } catch { }
    try { if ($script:exitEvent -ne $null) { $script:exitEvent.Close() } } catch { }
})
$timer.Start()
[void]$form.ShowDialog()
