; ==============================================================================
; Nexus Media Master Control - AutoHotkey v2 Desktop Suite
; High-performance media automation, 4K/Ultrawide window snapping,
; Jellyfin REST API scrobbling, and Kiosk launcher.
; ==============================================================================
#Requires AutoHotkey v2.0+
#SingleInstance Force
Persistent
SetWorkingDir A_ScriptDir
SendMode "Input"
SetTitleMatchMode 2

; ------------------------------------------------------------------------------
; Default Configuration & Runtime State
; ------------------------------------------------------------------------------
global ServerUrl := EnvGet("JELLYFIN_SERVER_URL") ? EnvGet("JELLYFIN_SERVER_URL") : "http://localhost:8096"
global ApiKey    := EnvGet("JELLYFIN_API_KEY") ? EnvGet("JELLYFIN_API_KEY") : ""
global UserId    := EnvGet("JELLYFIN_USER_ID") ? EnvGet("JELLYFIN_USER_ID") : ""
global ConfigFile := A_ScriptDir . "\..\config\system-specs.json"

; Load configuration if available
LoadConfig()

; Tray Menu Setup
A_IconTip := "Nexus Media Master Control"
TraySetIcon("shell32.dll", 138) ; Media icon
A_TrayMenu.Delete()
A_TrayMenu.Add("Nexus Media Master Control", (*) => ShowOSD("Nexus Media Control Active", "Ready for media commands", 2000, 0x00E50914))
A_TrayMenu.Add()
A_TrayMenu.Add("Launch Jellyfin (Kiosk)", (*) => LaunchJellyfinKiosk())
A_TrayMenu.Add("Snap Active Window (UltraWide 21:9 Center)", (*) => SnapUltrawideCenter())
A_TrayMenu.Add()
A_TrayMenu.Add("Reload Script", (*) => Reload())
A_TrayMenu.Add("Exit", (*) => ExitApp())

ShowOSD("Nexus Media Control", "System initialized and running (AHK v2)", 2500, 0x00E50914)
; ==============================================================================
; Section 1: Global Media Hotkeys & Jellyfin REST API Scrobbling
; ==============================================================================

; [Ctrl + Alt + Space] -> Global Smart Play/Pause across PotPlayer, MPC, Jellyfin, Browser
^!Space::
{
    if WinExist("ahk_exe PotPlayerMini64.exe") or WinExist("ahk_exe PotPlayer64.exe") {
        ControlSend("{Space}", , "ahk_exe PotPlayerMini64.exe")
        ControlSend("{Space}", , "ahk_exe PotPlayer64.exe")
        ShowOSD("PotPlayer", "Play / Pause Toggled", 1500, 0x002196F3)
    } else if WinExist("ahk_exe mpc-hc64.exe") or WinExist("ahk_exe mpc-be64.exe") {
        ControlSend("{Space}", , "ahk_exe mpc-hc64.exe")
        ControlSend("{Space}", , "ahk_exe mpc-be64.exe")
        ShowOSD("MPC Player", "Play / Pause Toggled", 1500, 0x002196F3)
    } else {
        Send("{Media_Play_Pause}")
        ShowOSD("Media Control", "Play / Pause Sent", 1200, 0x002196F3)
    }
}

; [Ctrl + Alt + Right] -> Next Episode / Next Chapter in Season
^!Right::
{
    if WinActive("ahk_exe PotPlayerMini64.exe") or WinActive("ahk_exe PotPlayer64.exe") or WinExist("ahk_exe PotPlayerMini64.exe") {
        activeHwnd := WinExist("ahk_exe PotPlayerMini64.exe") ? WinExist("ahk_exe PotPlayerMini64.exe") : WinExist("ahk_exe PotPlayer64.exe")
        ControlSend("{PgDn}", , activeHwnd)
        title := WinGetTitle(activeHwnd)
        ShowOSD("Next Episode", (title != "" ? title : "Switched to next in playlist"), 2000, 0x004CAF50)
    } else {
        Send("{Media_Next}")
        ShowOSD("Next Track", "Skipped to next media", 1500, 0x004CAF50)
    }
}

; [Ctrl + Alt + Left] -> Previous Episode / Previous Chapter
^!Left::
{
    if WinActive("ahk_exe PotPlayerMini64.exe") or WinActive("ahk_exe PotPlayer64.exe") or WinExist("ahk_exe PotPlayerMini64.exe") {
        activeHwnd := WinExist("ahk_exe PotPlayerMini64.exe") ? WinExist("ahk_exe PotPlayerMini64.exe") : WinExist("ahk_exe PotPlayer64.exe")
        ControlSend("{PgUp}", , activeHwnd)
        title := WinGetTitle(activeHwnd)
        ShowOSD("Previous Episode", (title != "" ? title : "Switched to previous in playlist"), 2000, 0x00FF9800)
    } else {
        Send("{Media_Prev}")
        ShowOSD("Prev Track", "Skipped to previous media", 1500, 0x00FF9800)
    }
}

; [Ctrl + Alt + W] -> Mark Current / Active Playing Item as Watched in Jellyfin (REST API)
^!w::
{
    MarkActiveItemWatched()
}
; ==============================================================================
; Section 2: Window Snapping for 4K and Ultrawide (21:9 / 32:9) Displays
; ==============================================================================

; [Win + Alt + C] -> Ultrawide Center Theater (21:9 ratio centered on current monitor)
#!c::
{
    SnapUltrawideCenter()
}

; [Win + Alt + Left] -> Snap 1/3 Left Column (ideal for sidechat / controls on ultrawide)
#!Left::
{
    SnapMonitorFraction(1, 3, 0)
}

; [Win + Alt + Down] -> Snap Middle 1/3 Column (or Middle 50% for standard screens)
#!Down::
{
    SnapMonitorFraction(1, 3, 1)
}

; [Win + Alt + Right] -> Snap 1/3 Right Column (ideal for browser / player on ultrawide)
#!Right::
{
    SnapMonitorFraction(1, 3, 2)
}

; [Win + Alt + Up] -> Snap Theater Center 60% with 16:9 / 21:9 ratio
#!Up::
{
    SnapTheaterCenter()
}

; [Win + Alt + M] -> Toggle Borderless Maximized / Fullscreen Clean
#!m::
{
    ToggleBorderlessFullscreen()
}
; ==============================================================================
; Section 3: Jellyfin Kiosk Launcher & Web Fullscreen Launcher
; ==============================================================================

; [Ctrl + Alt + J] -> Launch Jellyfin Web in Fullscreen Kiosk Mode (Edge / Chrome)
^!j::
{
    LaunchJellyfinKiosk()
}

LaunchJellyfinKiosk()
{
    global ServerUrl
    edgePaths := [
        "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
    ]
    chromePaths := [
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        A_AppData . "\..\Local\Google\Chrome\Application\chrome.exe"
    ]
    
    appUrl := ServerUrl . "/web/index.html#!/home"
    browserExe := ""
    
    ; Priority: Edge -> Chrome
    for path in edgePaths {
        if FileExist(path) {
            browserExe := path
            break
        }
    }
    if (browserExe == "") {
        for path in chromePaths {
            if FileExist(path) {
                browserExe := path
                break
            }
        }
    }

    if (browserExe != "") {
        ; Launch with dedicated media app profile and kiosk window
        kioskArgs := '--app="' . appUrl . '" --start-fullscreen --disable-pinch --overscroll-history-navigation=0'
        try {
            Run('"' . browserExe . '" ' . kioskArgs)
            ShowOSD("Jellyfin Kiosk", "Launched fullscreen media interface", 2500, 0x00E50914)
        } catch as err {
            Run(appUrl)
            ShowOSD("Jellyfin Web", "Launched default browser view", 2000, 0x00E50914)
        }
    } else {
        Run(appUrl)
        ShowOSD("Jellyfin Web", "Launched default browser view", 2000, 0x00E50914)
    }
}
; ==============================================================================
; Section 4: Jellyfin REST API Integration & Smart Scrobbler
; ==============================================================================

MarkActiveItemWatched()
{
    global ServerUrl, ApiKey, UserId

    ; 1. Try to find currently playing episode from PotPlayer title
    potTitle := ""
    if WinExist("ahk_exe PotPlayerMini64.exe") {
        potTitle := WinGetTitle("ahk_exe PotPlayerMini64.exe")
    } else if WinExist("ahk_exe PotPlayer64.exe") {
        potTitle := WinGetTitle("ahk_exe PotPlayer64.exe")
    }

    ; Clean up title
    cleanedTitle := RegExReplace(potTitle, " - PotPlayer.*$", "")
    cleanedTitle := Trim(cleanedTitle)

    ShowOSD("Scrobbler", "Searching Jellyfin for: " . (cleanedTitle != "" ? cleanedTitle : "Latest Playing Item"), 2000, 0x00FF9800)

    ; Make background curl request to query active session or search item
    itemId := ""
    if (cleanedTitle != "") {
        itemId := FindItemIdByName(cleanedTitle)
    }

    if (itemId == "") {
        itemId := GetLastPlayingItemId()
    }

    if (itemId != "") {
        success := ScrobbleItem(itemId)
        if (success) {
            ShowOSD("Scrobble Confirmed", "Marked as Played in Jellyfin`nID: " . itemId, 3500, 0x004CAF50)
        } else {
            ShowOSD("Scrobble Failed", "Server returned error for ID: " . itemId, 3000, 0x00F44336)
        }
    } else {
        ShowOSD("Scrobble Notice", "Could not locate active Jellyfin item ID.", 2500, 0x00E50914)
    }
}

FindItemIdByName(searchTerm)
{
    global ServerUrl, ApiKey, UserId
    encodedTerm := UrlEncode(searchTerm)
    endpoint := ServerUrl . "/Items?searchTerm=" . encodedTerm . "&userId=" . UserId . "&recursive=true&api_key=" . ApiKey
    
    jsonResp := HttpGet(endpoint)
    if (jsonResp != "" && InStr(jsonResp, '"Id":"')) {
        RegExMatch(jsonResp, '"Id":"([a-f0-9]+)"', &match)
        if (match) {
            return match[1]
        }
    }
    return ""
}

GetLastPlayingItemId()
{
    global ServerUrl, ApiKey, UserId
    endpoint := ServerUrl . "/Sessions?api_key=" . ApiKey
    jsonResp := HttpGet(endpoint)
    if (jsonResp != "" && InStr(jsonResp, '"NowPlayingItem":')) {
        RegExMatch(jsonResp, '"NowPlayingItem":\{"Name":".*?","Id":"([a-f0-9]+)"', &match)
        if (match) {
            return match[1]
        }
    }
    ; Fallback to latest resume item
    resumeEndpoint := ServerUrl . "/UserViews?userId=" . UserId . "&api_key=" . ApiKey
    return ""
}

ScrobbleItem(targetId)
{
    global ServerUrl, ApiKey, UserId
    endpoint := ServerUrl . "/Users/" . UserId . "/PlayedItems/" . targetId . "?api_key=" . ApiKey
    res := HttpPost(endpoint, "")
    return (res != "ERROR")
}
; ==============================================================================
; Section 5: Fast Window Snapping Math Engine (4K / 21:9 / 32:9 Multi-Monitor)
; ==============================================================================

SnapUltrawideCenter()
{
    activeHwnd := WinGetID("A")
    if !activeHwnd
        return

    mon := GetMonitorWorkAreaFromHwnd(activeHwnd)
    monW := mon.Right - mon.Left
    monH := mon.Bottom - mon.Top

    ; Target 21:9 ratio centered or 70% width
    targetW := Round(monW * 0.70)
    targetH := Round(monH * 0.88)
    targetX := mon.Left + Round((monW - targetW) / 2)
    targetY := mon.Top + Round((monH - targetH) / 2)

    WinRestore(activeHwnd)
    WinMove(targetX, targetY, targetW, targetH, activeHwnd)
    ShowOSD("Window Snap", "Ultrawide Center Theater (70%)", 1200, 0x009C27B0)
}

SnapTheaterCenter()
{
    activeHwnd := WinGetID("A")
    if !activeHwnd
        return

    mon := GetMonitorWorkAreaFromHwnd(activeHwnd)
    monW := mon.Right - mon.Left
    monH := mon.Bottom - mon.Top

    ; 16:9 / 60% theater box
    targetW := Round(monW * 0.60)
    targetH := Round(monH * 0.80)
    targetX := mon.Left + Round((monW - targetW) / 2)
    targetY := mon.Top + Round((monH - targetH) / 2)

    WinRestore(activeHwnd)
    WinMove(targetX, targetY, targetW, targetH, activeHwnd)
    ShowOSD("Window Snap", "Theater Center (60%)", 1200, 0x009C27B0)
}

SnapMonitorFraction(numerator, denominator, colIndex)
{
    activeHwnd := WinGetID("A")
    if !activeHwnd
        return

    mon := GetMonitorWorkAreaFromHwnd(activeHwnd)
    monW := mon.Right - mon.Left
    monH := mon.Bottom - mon.Top

    colW := Round(monW / denominator) * numerator
    targetX := mon.Left + (colIndex * Round(monW / denominator))
    targetY := mon.Top
    targetW := colW
    targetH := monH

    WinRestore(activeHwnd)
    WinMove(targetX, targetY, targetW, targetH, activeHwnd)
    ShowOSD("Window Snap", "Column " . (colIndex + 1) . " of " . denominator, 1200, 0x009C27B0)
}

ToggleBorderlessFullscreen()
{
    activeHwnd := WinGetID("A")
    if !activeHwnd
        return

    style := WinGetStyle(activeHwnd)
    ; Check if window has standard WS_CAPTION (0x00C00000)
    if (style & 0x00C00000) {
        ; Make Borderless
        WinSetStyle("-0x00C00000", activeHwnd) ; Remove WS_CAPTION
        WinSetStyle("-0x00040000", activeHwnd) ; Remove WS_THICKFRAME
        mon := GetMonitorWorkAreaFromHwnd(activeHwnd)
        WinMove(mon.Left, mon.Top, mon.Right - mon.Left, mon.Bottom - mon.Top, activeHwnd)
        ShowOSD("Window Mode", "Borderless Fullscreen Enabled", 1500, 0x00E50914)
    } else {
        ; Restore normal frame
        WinSetStyle("+0x00C00000", activeHwnd)
        WinSetStyle("+0x00040000", activeHwnd)
        ShowOSD("Window Mode", "Standard Window Restored", 1500, 0x00757575)
    }
}

GetMonitorWorkAreaFromHwnd(hwnd)
{
    hMon := DllCall("MonitorFromWindow", "Ptr", hwnd, "UInt", 2, "Ptr") ; MONITOR_DEFAULTTONEAREST
    
    ; MONITORINFO structure (40 bytes)
    monInfo := Buffer(40, 0)
    NumPut("UInt", 40, monInfo, 0)
    
    if DllCall("GetMonitorInfo", "Ptr", hMon, "Ptr", monInfo) {
        rcWorkLeft   := NumGet(monInfo, 20, "Int")
        rcWorkTop    := NumGet(monInfo, 24, "Int")
        rcWorkRight  := NumGet(monInfo, 28, "Int")
        rcWorkBottom := NumGet(monInfo, 32, "Int")
        return { Left: rcWorkLeft, Top: rcWorkTop, Right: rcWorkRight, Bottom: rcWorkBottom }
    }
    
    ; Fallback to primary work area
    MonitorGetWorkArea(1, &Left, &Top, &Right, &Bottom)
    return { Left: Left, Top: Top, Right: Right, Bottom: Bottom }
}
; ==============================================================================
; Section 6: High-Performance OSD Notification UI (Smooth Dark Theme)
; ==============================================================================

global OsdGui := ""
global OsdTimer := ""

ShowOSD(header, message, durationMs := 2000, accentColor := 0x00E50914)
{
    global OsdGui, OsdTimer

    if (OsdTimer != "") {
        SetTimer(OsdTimer, 0)
        OsdTimer := ""
    }

    if (OsdGui != "") {
        try OsdGui.Destroy()
    }

    OsdGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x00000020 +E0x08000000", "NexusOSD")
    OsdGui.BackColor := "0x141414"
    OsdGui.MarginX := 20
    OsdGui.MarginY := 14

    ; Accent bar
    hexColor := Format("{:06X}", accentColor & 0xFFFFFF)
    OsdGui.AddProgress("x0 y0 w6 h85 c" . hexColor . " Background0x141414", 100)

    ; Text controls
    OsdGui.SetFont("s11 bold cWhite", "Segoe UI")
    OsdGui.AddText("x20 y12 w340", header)

    OsdGui.SetFont("s9 norm cE0E0E0", "Segoe UI")
    OsdGui.AddText("x20 y36 w340", message)

    ; Position at Top-Right of Primary Monitor
    MonitorGetWorkArea(1, &monLeft, &monTop, &monRight, &monBottom)
    osdX := monRight - 390
    osdY := monTop + 40

    ; Make rounded & semi-transparent
    OsdGui.Show("x" . osdX . " y" . osdY . " w380 h80 NoActivate")
    try WinSetTransparent(235, OsdGui.Hwnd)
    
    ; Auto-hide timer
    OsdTimer := (*) => HideOSD()
    SetTimer(OsdTimer, -durationMs)
}

HideOSD()
{
    global OsdGui, OsdTimer
    if (OsdGui != "") {
        try OsdGui.Destroy()
        OsdGui := ""
    }
    OsdTimer := ""
}
; ==============================================================================
; Section 7: Fast HTTP / REST API Client (WinHttpRequest ComObject)
; ==============================================================================

HttpGet(url)
{
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.Open("GET", url, true)
        req.SetTimeouts(2000, 2000, 3000, 3000)
        req.Send()
        req.WaitForResponse(3)
        return req.ResponseText
    } catch {
        return ""
    }
}

HttpPost(url, jsonBody)
{
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.Open("POST", url, true)
        req.SetRequestHeader("Content-Type", "application/json")
        req.SetTimeouts(2000, 2000, 3000, 3000)
        req.Send(jsonBody)
        req.WaitForResponse(3)
        return req.ResponseText
    } catch {
        ; Fallback to curl.exe CLI if WinHttpRequest fails
        try {
            cmd := 'curl.exe -s -X POST "' . url . '" -H "Content-Type: application/json"'
            shell := ComObject("WScript.Shell")
            exec := shell.Exec(cmd)
            return exec.StdOut.ReadAll()
        } catch {
            return "ERROR"
        }
    }
}

UrlEncode(str)
{
    doc := ComObject("HTMLFile")
    doc.write('<meta http-equiv="X-UA-Compatible" content="IE=edge"/>')
    return doc.parentWindow.encodeURIComponent(str)
}

LoadConfig()
{
    global ServerUrl, ApiKey, UserId, ConfigFile
    if FileExist(ConfigFile) {
        try {
            content := FileRead(ConfigFile, "UTF-8")
            if InStr(content, '"server_url":') {
                RegExMatch(content, '"server_url":\s*"([^"]+)"', &mUrl)
                if (mUrl)
                    ServerUrl := mUrl[1]
            }
            if InStr(content, '"api_key":') {
                RegExMatch(content, '"api_key":\s*"([^"]+)"', &mKey)
                if (mKey)
                    ApiKey := mKey[1]
            }
            if InStr(content, '"user_id":') {
                RegExMatch(content, '"user_id":\s*"([^"]+)"', &mUser)
                if (mUser)
                    UserId := mUser[1]
            }
        }
    }
}
