# PotPlayer playback log watch console (10x)
# WinForms with 1s Timer. Pause-aware tracker companion.
# Features:
#   (F7)  Pause/follow toggle button (pauses auto-refresh, follow auto-scrolls when live).
#   (F8)  Errors-only filter toggle + text filter box (substring, case-insensitive).
#   (F9)  Always-on-top toggle + copy-selected-line button.
#   (F10) Robust coloring via -match only (no stored pattern objects; they are NULL in Tick)
#         + SilentlyContinue inside Tick. Secrets: none hardcoded.
param(
    [string]$EpisodeHint = "",
    [string]$ItemId = ""
)

$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

# Hint shown in title + red highlight. Fall back to ItemId when hint is empty.
$global:WL_hint = ""
try { $global:WL_hint = $EpisodeHint.Trim() } catch { $global:WL_hint = "" }
if ([string]::IsNullOrWhiteSpace($global:WL_hint)) {
    try { $global:WL_hint = $ItemId.Trim() } catch { $global:WL_hint = "" }
}
$global:WL_itemId = ""
try { $global:WL_itemId = $ItemId.Trim() } catch { $global:WL_itemId = "" }

# ---- Singleton: Global\PotPlayerWatchLogs, second instance takes over ----
$global:WL_mutex = $null
$global:WL_exitEvent = $null
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
try { $global:WL_mutex = New-Object System.Threading.Mutex($false, "Global\PotPlayerWatchLogs") }
catch { $global:WL_mutex = $null }
$global:WL_ownsMutex = $false
if ($global:WL_mutex -ne $null) {
    try { $global:WL_ownsMutex = $global:WL_mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $global:WL_ownsMutex = $true }
    catch { $global:WL_ownsMutex = $false }
    if (-not $global:WL_ownsMutex) {
        try { $oldEvt = Get-ExitEvent $false; if ($oldEvt -ne $null) { [void]$oldEvt.Set(); $oldEvt.Close() } } catch { }
        try { $global:WL_ownsMutex = $global:WL_mutex.WaitOne(3500) }
        catch [System.Threading.AbandonedMutexException] { $global:WL_ownsMutex = $true }
        catch { $global:WL_ownsMutex = $false }
    }
}
try {
    $global:WL_exitEvent = Get-ExitEvent $true
    if ($global:WL_exitEvent -ne $null -and $global:WL_ownsMutex) { [void]$global:WL_exitEvent.Reset() }
} catch { }

$logDir = "F:\Jellyfin\logs"
$launcherLog = Join-Path $logDir "potplayer-launcher.log" -ErrorAction SilentlyContinue
$proxyLog = Join-Path $logDir "torbox-proxy.log" -ErrorAction SilentlyContinue
$bridgeLog = Join-Path $logDir "potplayer-bridge.log" -ErrorAction SilentlyContinue

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
        $p = Get-Process -Name "PotPlayerMini64", "PotPlayer64", "PotPlayer" -ErrorAction SilentlyContinue
        return ($null -ne $p)
    } catch { return $false }
}

# ---- (F7/F8/F9/F10) View state: no stored pattern objects (NULL in Tick), use -match ----
$global:WL_lastSeen = Get-Date
$global:WL_paused = $false
$global:WL_follow = $true
$global:WL_errorsOnly = $false
$global:WL_filterText = ""
$global:WL_defaultColor = [System.Drawing.Color]::LightGray
$global:WL_redColor = [System.Drawing.Color]::FromArgb(255, 107, 107)
$global:WL_greenColor = [System.Drawing.Color]::FromArgb(105, 255, 150)
$global:WL_headerColor = [System.Drawing.Color]::FromArgb(255, 220, 100)

$form = New-Object System.Windows.Forms.Form
$form.Size = New-Object System.Drawing.Size(1000, 700)
$form.StartPosition = "CenterScreen"
$form.Topmost = $true

# ---- Top control bar ----
$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = [System.Windows.Forms.DockStyle]::Top
$panel.Height = 64
$form.Controls.Add($panel)

# (F7) Pause/follow toggle button.
$btnPauseFollow = New-Object System.Windows.Forms.Button
$btnPauseFollow.Location = New-Object System.Drawing.Point(8, 8)
$btnPauseFollow.Size = New-Object System.Drawing.Size(190, 24)
$btnPauseFollow.Text = "Following (click to pause)"
$panel.Controls.Add($btnPauseFollow)

# (F8) Errors-only filter toggle.
$chkErrorsOnly = New-Object System.Windows.Forms.CheckBox
$chkErrorsOnly.Location = New-Object System.Drawing.Point(206, 11)
$chkErrorsOnly.Size = New-Object System.Drawing.Size(95, 20)
$chkErrorsOnly.Text = "Errors only"
$chkErrorsOnly.Checked = $false
$panel.Controls.Add($chkErrorsOnly)

# (F8) Text filter box.
$lblFilter = New-Object System.Windows.Forms.Label
$lblFilter.Location = New-Object System.Drawing.Point(308, 13)
$lblFilter.Size = New-Object System.Drawing.Size(40, 20)
$lblFilter.Text = "Filter:"
$panel.Controls.Add($lblFilter)

$txtFilter = New-Object System.Windows.Forms.TextBox
$txtFilter.Location = New-Object System.Drawing.Point(348, 9)
$txtFilter.Size = New-Object System.Drawing.Size(200, 24)
$panel.Controls.Add($txtFilter)

# (F9) Always-on-top toggle.
$chkTopMost = New-Object System.Windows.Forms.CheckBox
$chkTopMost.Location = New-Object System.Drawing.Point(556, 11)
$chkTopMost.Size = New-Object System.Drawing.Size(110, 20)
$chkTopMost.Text = "Always on top"
$chkTopMost.Checked = $true
$panel.Controls.Add($chkTopMost)

# (F9) Copy-selected-line button.
$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Location = New-Object System.Drawing.Point(674, 8)
$btnCopy.Size = New-Object System.Drawing.Size(130, 24)
$btnCopy.Text = "Copy selected line"
$panel.Controls.Add($btnCopy)

$rtb = New-Object System.Windows.Forms.RichTextBox
$rtb.Dock = [System.Windows.Forms.DockStyle]::Fill
$rtb.ReadOnly = $true
$rtb.WordWrap = $false
$rtb.ScrollBars = "Both"
$rtb.HideSelection = $false
$rtb.Font = New-Object System.Drawing.Font("Consolas", 9)
$rtb.BackColor = [System.Drawing.Color]::FromArgb(12, 12, 12)
$rtb.ForeColor = [System.Drawing.Color]::LightGray
$form.Controls.Add($rtb)
$rtb.BringToFront()

function Add-ColorLine([string]$line, [System.Drawing.Color]$color) {
    try {
        $rtb.SelectionStart = $rtb.TextLength
        $rtb.SelectionLength = 0
        $rtb.SelectionColor = $color
        $rtb.AppendText($line + "`r`n")
    } catch {}
}

function Test-IsErrorLine([string]$line) {
    try {
        if ([string]::IsNullOrEmpty($line)) { return $false }
        # (F10) Robust coloring/filtering via -match operator only.
        if ($line -match '(ERROR|FAIL|EXCEPTION|502|429|416)') { return $true }
        if (-not [string]::IsNullOrWhiteSpace($global:WL_hint) -and $line.IndexOf($global:WL_hint, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        if (-not [string]::IsNullOrWhiteSpace($global:WL_itemId) -and $line.IndexOf($global:WL_itemId, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    } catch {}
    return $false
}

function Update-View {
    try {
        $rtb.SuspendLayout()
        $rtb.Clear()
        $sections = @(
            @{ Name = "potplayer-launcher.log"; Path = $launcherLog },
            @{ Name = "torbox-proxy.log"; Path = $proxyLog },
            @{ Name = "potplayer-bridge.log"; Path = $bridgeLog }
        )
        foreach ($s in $sections) {
            Add-ColorLine ("=== " + $s.Name + " (last 25) ===") $global:WL_headerColor
            $lines = @(Get-LogTail -Path $s.Path -Count 25 -ErrorAction SilentlyContinue)
            if ($lines.Count -eq 0) { $lines = @("(empty)") }
            foreach ($line in $lines) {
                try {
                    # (F8) Text filter: substring, case-insensitive.
                    if (-not [string]::IsNullOrWhiteSpace($global:WL_filterText)) {
                        if ($line.IndexOf($global:WL_filterText, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
                    }
                    # (F8) Errors-only filter.
                    if ($global:WL_errorsOnly) {
                        if (-not (Test-IsErrorLine $line)) { continue }
                    }
                    # (F10) Coloring via -match only.
                    $c = $global:WL_defaultColor
                    if ($line -match '(ERROR|FAIL|EXCEPTION|502|429|416)') { $c = $global:WL_redColor }
                    elseif (-not [string]::IsNullOrWhiteSpace($global:WL_hint) -and $line.IndexOf($global:WL_hint, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $c = $global:WL_redColor }
                    elseif (-not [string]::IsNullOrWhiteSpace($global:WL_itemId) -and $line.IndexOf($global:WL_itemId, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $c = $global:WL_redColor }
                    elseif ($line -match '(206|Playing|HIT)') { $c = $global:WL_greenColor }
                    Add-ColorLine $line $c
                } catch {}
            }
            Add-ColorLine "" $global:WL_defaultColor
        }
        # (F7) Follow: auto-scroll only when follow is on.
        if ($global:WL_follow) {
            try {
                $rtb.SelectionStart = $rtb.TextLength
                $rtb.ScrollToCaret()
            } catch {}
        }
        $rtb.ResumeLayout()
    } catch {}
}

# ---- Control wiring ----
$btnPauseFollow.Add_Click({
    try {
        $global:WL_paused = -not $global:WL_paused
        $global:WL_follow = -not $global:WL_paused
        if ($global:WL_paused) { $btnPauseFollow.Text = "Paused (click to follow)" }
        else { $btnPauseFollow.Text = "Following (click to pause)"; Update-View }
    } catch {}
})

$chkErrorsOnly.Add_CheckedChanged({
    try {
        $global:WL_errorsOnly = $chkErrorsOnly.Checked
        if (-not $global:WL_paused) { Update-View }
    } catch {}
})

$txtFilter.Add_TextChanged({
    try {
        $global:WL_filterText = $txtFilter.Text
        if (-not $global:WL_paused) { Update-View }
    } catch {}
})

$chkTopMost.Add_CheckedChanged({
    try { $form.Topmost = $chkTopMost.Checked } catch {}
})

$btnCopy.Add_Click({
    try {
        $textToCopy = ""
        try { $textToCopy = $rtb.SelectedText } catch { $textToCopy = "" }
        if ([string]::IsNullOrEmpty($textToCopy)) {
            # No selection: copy the line containing the caret.
            try {
                $caret = $rtb.SelectionStart
                $lineIdx = $rtb.GetLineFromCharIndex($caret)
                $all = $rtb.Lines
                if ($all -ne $null -and $lineIdx -ge 0 -and $lineIdx -lt $all.Length) {
                    $textToCopy = $all[$lineIdx]
                }
            } catch {}
        }
        if (-not [string]::IsNullOrEmpty($textToCopy)) {
            try { [System.Windows.Forms.Clipboard]::SetText($textToCopy) } catch {}
        }
    } catch {}
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        # Takeover: if a newer instance signalled us, close so it can own the mutex.
        try {
            if ($global:WL_exitEvent -ne $null -and $global:WL_exitEvent.WaitOne(0)) { $form.Close(); return }
        } catch { }
        $running = $false
        try { $running = Test-PotPlayerRunning -ErrorAction SilentlyContinue } catch { $running = $false }
        if ($running) {
            $global:WL_lastSeen = Get-Date -ErrorAction SilentlyContinue
            if ([string]::IsNullOrWhiteSpace($global:WL_hint)) { $form.Text = "WATCHING - LIVE" }
            else { $form.Text = "WATCHING: " + $global:WL_hint + " - LIVE" }
        } else {
            $idleSec = 0
            try { $idleSec = [int]((Get-Date) - $global:WL_lastSeen).TotalSeconds } catch { $idleSec = 0 }
            $left = 60 - $idleSec
            if ($left -lt 0) { $left = 0 }
            if ([string]::IsNullOrWhiteSpace($global:WL_hint)) { $form.Text = "PotPlayer idle - closing in " + $left + "s..." }
            else { $form.Text = "WATCHING: " + $global:WL_hint + " - idle, closing in " + $left + "s..." }
            if ($idleSec -ge 60) { $form.Close(); return }
        }
        # (F7) Paused: skip refresh entirely.
        if ($global:WL_paused) { return }
        try { Update-View -ErrorAction SilentlyContinue } catch { }
    } catch { }
})
$form.Add_Shown({ Update-View; $rtb.Focus() })
$form.Add_FormClosed({
    try { $timer.Stop() } catch { }
    try { if ($global:WL_mutex -ne $null -and $global:WL_ownsMutex) { $global:WL_mutex.ReleaseMutex() } } catch { }
    try { if ($global:WL_mutex -ne $null) { $global:WL_mutex.Close() } } catch { }
    try { if ($global:WL_exitEvent -ne $null) { $global:WL_exitEvent.Close() } } catch { }
})
$timer.Start()
[void]$form.ShowDialog()
