<#
.SYNOPSIS
    Creates the rclone-storage MCP server (Python JSON-RPC bridge over rclone).
.DESCRIPTION
    Generates mcp-servers/rclone-storage/server.py, locks down rclone.conf ACLs,
    and optionally registers a daily connectivity health-check scheduled task.

    InstallOps hardening (10 features):
      1. Idempotent re-runs (identical server.py is left in place).
      2. Admin-rights check with friendly message + self-elevate offer.
      3. Scheduled-task existence verification after creation (-RegisterTask).
      4. Rollback on failure (restores *.bak files, unregisters partial task).
      5. -Uninstall switch (removes server.py, task, version stamp).
      6. Registry backup helper (.reg export) included; skipped with a note
         (this installer performs no registry writes).
      7. rclone.conf ACL lockdown to Administrators + owner.
      8. Version stamp file after successful install.
      9. Preflight checks (pwsh version, paths exist, RC ports free).
     10. Called by install-all.ps1 in dependency order (after rclone service).

    Never hardcodes secrets: all paths/remotes are parameters, no tokens or passwords.
#>

param (
    [string]$BaseDir = 'F:\Jellyfin',
    [string]$RcloneExe = 'F:\Jellyfin\server\rclone.exe',
    [string]$ConfigPath = 'F:\Jellyfin\config\rclone.conf',
    [string]$McpDir = "",
    [string]$RemoteName = 'gdrive-media:',
    [string]$TaskName = 'Rclone MCP Health Check',
    [switch]$RegisterTask,
    [string]$VersionDir = "",
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'create_rclone_mcp'
$ScriptVersion = '1.0.0'

#region InstallOps shared helpers
$script:BackupLedger = New-Object System.Collections.Generic.List[string]
$script:RegBackups = New-Object System.Collections.Generic.List[string]

if ([string]::IsNullOrWhiteSpace($McpDir)) {
    $McpDir = Join-Path $BaseDir 'mcp-servers\rclone-storage'
}
if ([string]::IsNullOrWhiteSpace($VersionDir)) {
    $rootHint = $PSScriptRoot
    if ((Split-Path $rootHint -Leaf) -ieq 'scripts') { $rootHint = Split-Path $rootHint -Parent }
    $script:VersionDir = Join-Path $rootHint '.install-versions'
} else {
    $script:VersionDir = $VersionDir
}
$script:RegBackupDir = Join-Path $script:VersionDir 'registry-backups'

$script:ElevateArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
foreach ($k in $PSBoundParameters.Keys) {
    $v = $PSBoundParameters[$k]
    if ($v -is [switch]) { if ($v.IsPresent) { $script:ElevateArgs += "-$k" } }
    elseif ($null -ne $v -and "$v" -ne '') { $script:ElevateArgs += "-$k"; $script:ElevateArgs += "$v" }
}

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsPrincipalRole]::Administrator)
}

function Test-Interactive {
    try {
        return [Environment]::UserInteractive -and (-not [Console]::IsInputRedirected)
    } catch { return $false }
}

function Request-Elevation {
    param([string]$Reason)
    Write-Host "[!] Administrator rights required. $Reason" -ForegroundColor Yellow
    Write-Host "    Please re-run this script from an elevated (Run as Administrator) pwsh session." -ForegroundColor Yellow
    if (Test-Interactive) {
        $answer = Read-Host '    Re-launch automatically as Administrator now? [Y/n]'
        if ([string]::IsNullOrWhiteSpace($answer) -or ($answer -match '^(?i)y(es)?$')) {
            $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
            if (-not $pwsh) { $pwsh = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" }
            Start-Process -FilePath $pwsh -ArgumentList $script:ElevateArgs -Verb RunAs
            exit 0
        }
    }
    throw 'Administrator rights are required. Re-run as Administrator.'
}

function Test-PortFree {
    param([int]$Port)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(500)
        $connected = $ok -and $client.Connected
        $client.Close()
        return (-not $connected)
    } catch { return $true }
}

function Backup-File {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $bak = "$Path.bak"
    if (Test-Path -LiteralPath $bak) {
        Move-Item -LiteralPath $bak -Destination ("$bak.{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
    }
    Copy-Item -LiteralPath $Path -Destination $bak -Force
    [void]$script:BackupLedger.Add("$Path|$bak")
    Write-Host "[backup] $Path -> $bak" -ForegroundColor Gray
    return $bak
}

function Restore-Backups {
    foreach ($entry in $script:BackupLedger) {
        $parts = $entry -split '\|', 2
        if (($parts.Count -eq 2) -and (Test-Path -LiteralPath $parts[1])) {
            Copy-Item -LiteralPath $parts[1] -Destination $parts[0] -Force
            Write-Host ("[rollback] Restored {0} from {1}" -f $parts[0], $parts[1]) -ForegroundColor Yellow
        }
    }
}

function Backup-RegistryKey {
    param([string]$RegPath)
    # F6 helper (N/A here: this installer performs no registry writes).
    Write-Host "[*] No registry writes required; skipping .reg backup." -ForegroundColor Gray
    return $null
}

function Restore-RegistryBackups {
    foreach ($f in $script:RegBackups) {
        if (Test-Path -LiteralPath $f) {
            Start-Process -FilePath "$env:WINDIR\System32\reg.exe" `
                -ArgumentList 'import', ('"{0}"' -f $f) -Wait -NoNewWindow | Out-Null
            Write-Host "[rollback] Re-imported registry backup $f" -ForegroundColor Yellow
        }
    }
}

function Confirm-ScheduledTaskExists {
    param([string]$Name)
    # F3: scheduled-task existence verification after creation.
    $t = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $t) { throw "Scheduled task '$Name' was not found after creation." }
    $info = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction SilentlyContinue
    Write-Host ("[verify] Task '{0}' state={1} lastRun={2} result={3}" -f $t.TaskName, $t.State, $info.LastRunTime, $info.LastTaskResult) -ForegroundColor Green
    return $t
}

function Lock-RcloneConfAcl {
    param([string]$Path)
    # F7: ACL lockdown to Administrators + owner only.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Host "[*] rclone.conf not found at $Path; skipping ACL lockdown." -ForegroundColor Gray
        return $false
    }
    $user = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    & "$env:WINDIR\System32\icacls.exe" $Path /inheritance:r | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls /inheritance:r failed on $Path (exit $LASTEXITCODE)." }
    & "$env:WINDIR\System32\icacls.exe" $Path /grant:r 'Administrators:F' ('{0}:F' -f $user) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls /grant failed on $Path (exit $LASTEXITCODE)." }
    Write-Host "[+] ACL lockdown applied to $Path (Administrators + $user only)" -ForegroundColor Green
    return $true
}

function Write-VersionStamp {
    param([string]$Name, [string]$Version, [hashtable]$Extra)
    New-Item -ItemType Directory -Force -Path $script:VersionDir | Out-Null
    $obj = [ordered]@{
        name        = $Name
        version     = $Version
        installedAt = (Get-Date).ToString('o')
        user        = ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
        computer    = $env:COMPUTERNAME
        status      = 'installed'
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $obj[$k] = $Extra[$k] } }
    $out = Join-Path $script:VersionDir ("$Name.version.json")
    ($obj | ConvertTo-Json -Depth 5) | Out-File -LiteralPath $out -Encoding UTF8
    Write-Host "[+] Version stamp written: $out" -ForegroundColor Green
    return $out
}

function Remove-VersionStamp {
    param([string]$Name)
    $out = Join-Path $script:VersionDir ("$Name.version.json")
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
}
#endregion

# Test 1: Python rclone wrapper / bridge
Write-Host "Creating multi-cloud storage management server for rclone..." -ForegroundColor Cyan

# F2: Admin-rights check with friendly message + self-elevate offer.
if (-not (Test-IsAdmin)) {
    Request-Elevation -Reason 'Writing the MCP server and locking rclone.conf ACLs requires elevation.'
}

$serverPy = Join-Path $McpDir 'server.py'

if ($Uninstall) {
    # F5: Uninstall path.
    Write-Host "Removing rclone MCP server..." -ForegroundColor Cyan
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "[remove] Unregistered scheduled task '$TaskName'." -ForegroundColor Yellow
    }
    if (Test-Path -LiteralPath $serverPy) {
        Remove-Item -LiteralPath $serverPy -Force
        Write-Host "[remove] Deleted $serverPy" -ForegroundColor Yellow
    } else {
        Write-Host "[*] $serverPy already absent." -ForegroundColor Gray
    }
    if ((Test-Path -LiteralPath $McpDir) -and -not (Get-ChildItem -LiteralPath $McpDir -Force | Select-Object -First 1)) {
        Remove-Item -LiteralPath $McpDir -Force
    }
    Remove-VersionStamp -Name $ScriptName
    Write-Host "[SUCCESS] Rclone MCP server uninstalled (rclone.conf preserved)." -ForegroundColor Green
    exit 0
}

$createdTask = $false

try {
    # F9: preflight (pwsh version, creatable paths, RC ports free-or-warn).
    if ($PSVersionTable.PSVersion -lt [version]'7.0') {
        throw ("pwsh 7.0+ is required (found {0}). Install PowerShell 7 and re-run." -f $PSVersionTable.PSVersion)
    }
    Write-Host ("[+] Preflight: pwsh {0} OK" -f $PSVersionTable.PSVersion) -ForegroundColor Green
    New-Item -ItemType Directory -Force -Path $McpDir | Out-Null
    Write-Host "[+] Preflight: MCP directory ready ($McpDir)" -ForegroundColor Green
    if (-not (Test-Path -LiteralPath $RcloneExe -PathType Leaf)) {
        Write-Host "[!] Preflight: rclone.exe not found at $RcloneExe (server will fail at runtime until fixed)." -ForegroundColor Yellow
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        Write-Host "[!] Preflight: rclone.conf not found at $ConfigPath (create it from the template first)." -ForegroundColor Yellow
    }
    foreach ($port in @(5572, 5573)) {
        if (Test-PortFree -Port $port) {
            Write-Host "[+] Preflight: TCP port $port is free" -ForegroundColor Green
        } else {
            Write-Host "[*] Preflight: TCP port $port is in use (expected when the rclone mount service runs)." -ForegroundColor Gray
        }
    }

    # F7: rclone.conf ACL lockdown before the MCP server consumes it.
    [void](Backup-File -Path $ConfigPath)
    [void](Lock-RcloneConfAcl -Path $ConfigPath)

    # Desired server.py content (paths injected; no secrets embedded).
    $pyExe = $RcloneExe.Replace('\', '\\')
    $pyConf = $ConfigPath.Replace('\', '\\')
    $template = @'
import sys
import json
import subprocess
import os

def run_rclone(args):
    cmd = ["__RCLONE_EXE__", "--config", "__RCLONE_CONF__"] + args
    res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
    return res.stdout, res.stderr, res.returncode

def main():
    while True:
        try:
            line = sys.stdin.readline()
            if not line:
                break
            req = json.loads(line)
            req_id = req.get("id")
            method = req.get("method")

            if method == "initialize":
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "protocolVersion": "2024-11-05",
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "rclone-storage-mcp", "version": "1.0.0"}
                    }
                }
                sys.stdout.write(json.dumps(resp) + "\n")
                sys.stdout.flush()

            elif method == "tools/list":
                tools = [
                    {
                        "name": "rclone_list_files",
                        "description": "List files in any mounted or remote cloud directory (e.g. gdrive-media:Motion Picture)",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "remote_path": {"type": "string", "description": "Remote path like 'gdrive-media:Motion Picture' or 'gdrive-media:'"},
                                "recursive": {"type": "boolean", "default": False}
                            },
                            "required": ["remote_path"]
                        }
                    },
                    {
                        "name": "rclone_rename_or_move",
                        "description": "Fast server-side rename or move file in cloud without re-uploading",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "source": {"type": "string", "description": "Source path e.g. 'gdrive-media:Motion Picture/old.mkv'"},
                                "destination": {"type": "string", "description": "Dest path e.g. 'gdrive-media:Motion Picture/new.mkv'"}
                            },
                            "required": ["source", "destination"]
                        }
                    },
                    {
                        "name": "rclone_command",
                        "description": "Execute any direct rclone command (lsf, moveto, copyto, mkdir, purge, rmdir, check)",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "subcommand": {"type": "string", "description": "e.g. lsf, moveto, copyto, about, size"},
                                "args": {"type": "array", "items": {"type": "string"}, "description": "Command arguments"}
                            },
                            "required": ["subcommand", "args"]
                        }
                    }
                ]
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {"tools": tools}
                }
                sys.stdout.write(json.dumps(resp) + "\n")
                sys.stdout.flush()

            elif method == "tools/call":
                params = req.get("params", {})
                name = params.get("name")
                args = params.get("arguments", {})

                if name == "rclone_list_files":
                    rpath = args.get("remote_path", "")
                    rec = args.get("recursive", False)
                    rargs = ["lsjson", rpath]
                    if rec:
                        rargs.append("-R")
                    out, err, code = run_rclone(rargs)
                    content = out if code == 0 else f"Error ({code}): {err}"
                    resp = {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"content": [{"type": "text", "text": content}]}
                    }
                    sys.stdout.write(json.dumps(resp) + "\n")
                    sys.stdout.flush()

                elif name == "rclone_rename_or_move":
                    src = args.get("source")
                    dst = args.get("destination")
                    out, err, code = run_rclone(["moveto", src, dst])
                    msg = f"Successfully moved/renamed '{src}' -> '{dst}'" if code == 0 else f"Error ({code}): {err}"
                    resp = {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"content": [{"type": "text", "text": msg}]}
                    }
                    sys.stdout.write(json.dumps(resp) + "\n")
                    sys.stdout.flush()

                elif name == "rclone_command":
                    subcmd = args.get("subcommand")
                    cargs = args.get("args", [])
                    out, err, code = run_rclone([subcmd] + cargs)
                    result_text = out if out else (f"Success (Code {code})" if code == 0 else f"Error ({code}): {err}")
                    resp = {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"content": [{"type": "text", "text": result_text}]}
                    }
                    sys.stdout.write(json.dumps(resp) + "\n")
                    sys.stdout.flush()
                else:
                    resp = {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "error": {"code": -32601, "message": f"Tool not found: {name}"}
                    }
                    sys.stdout.write(json.dumps(resp) + "\n")
                    sys.stdout.flush()

        except Exception as e:
            err_resp = {
                "jsonrpc": "2.0",
                "id": req.get("id") if "req" in locals() else None,
                "error": {"code": -32603, "message": str(e)}
            }
            sys.stdout.write(json.dumps(err_resp) + "\n")
            sys.stdout.flush()

if __name__ == "__main__":
    main()
'@
    $desired = $template.Replace('__RCLONE_EXE__', $pyExe).Replace('__RCLONE_CONF__', $pyConf)

    # F1: idempotency — leave identical server.py in place (upgrade otherwise).
    $existingContent = $null
    if (Test-Path -LiteralPath $serverPy -PathType Leaf) {
        $existingContent = Get-Content -LiteralPath $serverPy -Raw -Encoding UTF8
    }
    if ($null -ne $existingContent -and ($existingContent -ceq $desired -or ($existingContent.TrimEnd() -ceq $desired.TrimEnd()))) {
        Write-Host "[=] server.py already up to date; leaving in place." -ForegroundColor Gray
    } else {
        if ($null -ne $existingContent) {
            Write-Host "[*] Existing server.py differs; upgrading in place..." -ForegroundColor Yellow
        }
        # F4: back up existing server.py (*.bak) before overwriting.
        [void](Backup-File -Path $serverPy)
        $desired | Out-File $serverPy -Encoding UTF8 -NoNewline:$false
        Write-Host "Created server script at $serverPy" -ForegroundColor Green
    }

    # Verification: file exists and (when Python is present) compiles.
    if (-not (Test-Path -LiteralPath $serverPy -PathType Leaf)) {
        throw "Verification failed: $serverPy was not created."
    }
    $python = (Get-Command python.exe -ErrorAction SilentlyContinue) ?? (Get-Command python3.exe -ErrorAction SilentlyContinue)
    if ($python) {
        & $python.Source -m py_compile $serverPy
        if ($LASTEXITCODE -ne 0) { throw "Verification failed: server.py does not compile (exit $LASTEXITCODE)." }
        Write-Host "[verify] server.py compiles OK" -ForegroundColor Green
    } else {
        Write-Host "[*] Python not found; skipping py_compile check (file presence verified)." -ForegroundColor Gray
    }

    if ($RegisterTask) {
        # Optional daily connectivity probe: rclone lsf against the remote.
        $logDir = Join-Path $BaseDir 'logs'
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        $probeLog = Join-Path $logDir 'rclone-mcp-probe.log'
        $probeAction = New-ScheduledTaskAction -Execute $RcloneExe `
            -Argument ('lsf "{0}" --config "{1}" >> "{2}" 2>&1' -f $RemoteName, $ConfigPath, $probeLog)
        $probeTrigger = New-ScheduledTaskTrigger -Daily -At '04:30'
        $probePrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Highest
        $probeSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        $already = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $TaskName -Action $probeAction -Trigger $probeTrigger `
            -Principal $probePrincipal -Settings $probeSettings `
            -Description 'Daily rclone connectivity probe for the rclone-storage MCP server.' -Force | Out-Null
        if (-not $already) { $createdTask = $true }
        # F3: scheduled-task existence verification after creation.
        [void](Confirm-ScheduledTaskExists -Name $TaskName)
    } else {
        Write-Host "[*] -RegisterTask not requested; skipping scheduled-task creation." -ForegroundColor Gray
    }

    # F8: version stamp after successful install.
    [void](Write-VersionStamp -Name $ScriptName -Version $ScriptVersion -Extra @{
            server = $serverPy; task = ($RegisterTask ? $TaskName : $null)
        })

    Write-Host "[SUCCESS] Rclone MCP server ready at $serverPy" -ForegroundColor Green
} catch {
    Write-Host ("[ERROR] MCP creation failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    # F4: rollback on failure (restore *.bak files; remove task only if we created it).
    Restore-Backups
    Restore-RegistryBackups
    if ($createdTask) {
        Write-Host "[rollback] Unregistering partially created task '$TaskName'..." -ForegroundColor Yellow
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    exit 1
}
