[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 8080
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workshopRoot = $PSScriptRoot
$expectedExe = Join-Path $workshopRoot "bin\llama-server.exe"
$pidFile = Join-Path $workshopRoot ".state\llama-server.pid"
$serverInfoFile = Join-Path $workshopRoot ".state\llama-server.json"

function Test-ExpectedServerProcess {
    param($ProcessInfo)
    if ($null -eq $ProcessInfo) { return $false }
    try {
        if ($ProcessInfo.Path) {
            return [string]::Equals(
                [IO.Path]::GetFullPath($ProcessInfo.Path),
                [IO.Path]::GetFullPath($expectedExe),
                [StringComparison]::OrdinalIgnoreCase
            )
        }
    }
    catch {
        return $false
    }
    return $false
}

$serverProcess = $null
$serverPid = 0
if (Test-Path -LiteralPath $pidFile) {
    $pidText = (Get-Content -LiteralPath $pidFile -Raw).Trim()
    if ([int]::TryParse($pidText, [ref]$serverPid)) {
        $candidate = Get-Process -Id $serverPid -ErrorAction SilentlyContinue
        if (Test-ExpectedServerProcess $candidate) {
            $serverProcess = $candidate
        }
    }
}

if ($null -eq $serverProcess) {
    $listenerPids = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique)
    foreach ($listenerPid in $listenerPids) {
        $candidate = Get-Process -Id $listenerPid -ErrorAction SilentlyContinue
        if (Test-ExpectedServerProcess $candidate) {
            $serverProcess = $candidate
            $serverPid = [int]$listenerPid
            break
        }
    }
}

if ($null -eq $serverProcess) {
    if (Test-Path -LiteralPath $pidFile) { Remove-Item -LiteralPath $pidFile -Force }
    if (Test-Path -LiteralPath $serverInfoFile) { Remove-Item -LiteralPath $serverInfoFile -Force }
    Write-Host "No running llama-server belonging to this workshop package was found."
    return
}

Stop-Process -Id $serverPid -Force
Start-Sleep -Seconds 1
if (Test-Path -LiteralPath $pidFile) { Remove-Item -LiteralPath $pidFile -Force }
if (Test-Path -LiteralPath $serverInfoFile) { Remove-Item -LiteralPath $serverInfoFile -Force }
Write-Host "[OK] Workshop llama-server process $serverPid stopped." -ForegroundColor Green
