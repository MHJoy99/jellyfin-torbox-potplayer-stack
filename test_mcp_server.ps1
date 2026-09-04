<#
.SYNOPSIS
    Assert-based smoke test for the rclone-storage MCP server (stdio JSON-RPC).
.DESCRIPTION
    Spawns server.py, asserts initialize/tools-list/tools-call contracts, and
    verifies the new list_remotes + transfer_status tools are advertised.
    Exits nonzero on any failure. Never hardcodes secrets.
.PARAMETER PythonExe
    Python interpreter. Defaults to $env:MCP_PYTHON or python on PATH.
.PARAMETER ServerScript
    Path to server.py. Defaults to sibling mcp-servers/rclone-storage/server.py.
.PARAMETER TimeoutSec
    Per-read timeout in seconds. Default 10.
#>
[CmdletBinding()]
param(
    [string]$PythonExe = $(if ($env:MCP_PYTHON) { $env:MCP_PYTHON } else { 'python' }),
    [string]$ServerScript = $(if ($env:MCP_SERVER_PY) { $env:MCP_SERVER_PY } else { (Join-Path $PSScriptRoot 'mcp-servers/rclone-storage/server.py') }),
    [int]$TimeoutSec = 10
)

$ErrorActionPreference = 'Continue'
$script:passed = 0
$script:failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        $script:passed++
        Write-Host "PASS: $Name"
    } else {
        $script:failed++
        Write-Host "FAIL: $Name $Detail"
    }
}

function Read-JsonLine {
    param($Process, [int]$Timeout = 10)
    $task = $Process.StandardOutput.ReadLineAsync()
    $done = $task.Wait($Timeout * 1000)
    if (-not $done) { throw "Timed out waiting for MCP response after ${Timeout}s" }
    $line = $task.Result
    if ([string]::IsNullOrWhiteSpace($line)) { throw 'Empty response from MCP server' }
    return ($line | ConvertFrom-Json)
}

# Fallback: resolve server.py relative to worktree root when PSSCriptRoot differs.
if (-not (Test-Path -LiteralPath $ServerScript)) {
    $candidates = @(
        (Join-Path (Get-Location) 'mcp-servers/rclone-storage/server.py'),
        'F:\Jellyfin\mcp-servers\rclone-storage\server.py'
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { $ServerScript = $c; break }
    }
}
Assert-True (Test-Path -LiteralPath $ServerScript) "MCP server script exists at $ServerScript"

$p = $null
try {
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = $PythonExe
    $pinfo.Arguments = "`"$ServerScript`""
    $pinfo.RedirectStandardInput = $true
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError = $true
    $pinfo.UseShellExecute = $false
    $pinfo.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($pinfo)
    Assert-True ($null -ne $p -and -not $p.HasExited) 'MCP server process started'

    # 1. initialize
    $p.StandardInput.WriteLine('{"jsonrpc":"2.0","id":1,"method":"initialize"}')
    $p.StandardInput.Flush()
    $initRes = Read-JsonLine $p $TimeoutSec
    Assert-True ($initRes.id -eq 1) 'initialize: id echoes'
    Assert-True ($null -ne $initRes.result.serverInfo) 'initialize: serverInfo present'
    Write-Host "Init server: $($initRes.result.serverInfo.name) v$($initRes.result.serverInfo.version)"

    # 2. tools/list must include 5 tools (3 baseline + 2 new).
    $p.StandardInput.WriteLine('{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
    $p.StandardInput.Flush()
    $toolsRes = Read-JsonLine $p $TimeoutSec
    $toolNames = @($toolsRes.result.tools | ForEach-Object { $_.name })
    Write-Host "Tools advertised: $($toolNames -join ', ')"
    Assert-True ($toolNames -contains 'rclone_list_files') 'tools/list contains rclone_list_files'
    Assert-True ($toolNames -contains 'rclone_rename_or_move') 'tools/list contains rclone_rename_or_move'
    Assert-True ($toolNames -contains 'rclone_command') 'tools/list contains rclone_command'
    Assert-True ($toolNames -contains 'list_remotes') 'tools/list contains list_remotes (new)'
    Assert-True ($toolNames -contains 'transfer_status') 'tools/list contains transfer_status (new)'

    # 3. tools/call list_remotes (no args) should return result content (or controlled error, not crash).
    $p.StandardInput.WriteLine('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_remotes","arguments":{}}}')
    $p.StandardInput.Flush()
    $callRes = Read-JsonLine $p $TimeoutSec
    Assert-True ($callRes.id -eq 3) 'list_remotes: id echoes'
    Assert-True ($null -ne $callRes.result -or $null -ne $callRes.error) 'list_remotes: result or error envelope'

    # 4. tools/call transfer_status should validate and respond.
    $p.StandardInput.WriteLine('{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"transfer_status","arguments":{}}}')
    $p.StandardInput.Flush()
    $tsRes = Read-JsonLine $p $TimeoutSec
    Assert-True ($tsRes.id -eq 4) 'transfer_status: id echoes'
    Assert-True ($null -ne $tsRes.result -or $null -ne $tsRes.error) 'transfer_status: result or error envelope'

    # 5. strict validation: invalid tool args must yield error, not unhandled crash.
    $p.StandardInput.WriteLine('{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"rclone_command","arguments":{"subcommand":"; rm -rf","args":[]}}}')
    $p.StandardInput.Flush()
    $badRes = Read-JsonLine $p $TimeoutSec
    $isValidationError = ($null -ne $badRes.error) -or (($badRes.result.content[0].text -match '(?i)invalid|not allowed|error'))
    Assert-True $isValidationError 'strict validation rejects unsafe subcommand'
} catch {
    $script:failed++
    Write-Host "FAIL: exception during MCP test: $($_.Exception.Message)"
} finally {
    try {
        if ($p -and -not $p.HasExited) { $p.Kill() }
    } catch {}
}

Write-Host "---- SUMMARY: passed=$script:passed failed=$script:failed ----"
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
