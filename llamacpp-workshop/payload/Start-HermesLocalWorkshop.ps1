[CmdletBinding()]
param(
    [ValidateRange(30, 900)]
    [int]$WaitSeconds = 300,

    [ValidateRange(1024, 65535)]
    [int]$Port = 8080
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workshopRoot = $PSScriptRoot
$serverExe = Join-Path $workshopRoot "bin\llama-server.exe"
$modelPath = Join-Path $workshopRoot "models\gemma-4-26B_q4_0-it.gguf"
$stateDirectory = Join-Path $workshopRoot ".state"
$logDirectory = Join-Path $workshopRoot "logs"
$pidFile = Join-Path $stateDirectory "llama-server.pid"
$serverInfoFile = Join-Path $stateDirectory "llama-server.json"
$modelAlias = "gemma-4-26b-a4b-local"
$healthUrl = "http://127.0.0.1:$Port/health"
$modelsUrl = "http://127.0.0.1:$Port/v1/models"

function Write-AtomicTextFile {
    param([string]$LiteralPath, [string]$Content)
    $temporaryPath = "$LiteralPath.tmp-$PID"
    try {
        [IO.File]::WriteAllText($temporaryPath, $Content, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporaryPath -Destination $LiteralPath -Force
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-WorkshopEndpoint {
    try {
        $health = Invoke-RestMethod -Uri $healthUrl -Method Get -TimeoutSec 5
        $models = Invoke-RestMethod -Uri $modelsUrl -Method Get -TimeoutSec 10
        $ids = @($models.data | ForEach-Object { [string]$_.id })
        return ($null -ne $health -and $ids -contains $modelAlias)
    }
    catch {
        return $false
    }
}

if (-not (Test-Path -LiteralPath $serverExe)) {
    throw "llama-server.exe is missing: $serverExe"
}
if (-not (Test-Path -LiteralPath $modelPath)) {
    throw "Gemma 4 is missing: $modelPath. Run Install-HermesLocalWorkshop.ps1 first."
}

if (Test-WorkshopEndpoint) {
    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    $readyListener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($readyListener) {
        Write-AtomicTextFile -LiteralPath $pidFile -Content ([string]$readyListener.OwningProcess)
    }
    Write-Host "[OK] Gemma 4 is already available at http://127.0.0.1:$Port/v1" -ForegroundColor Green
    return
}

$existingListener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($existingListener) {
    $ownerIds = @($existingListener | Select-Object -ExpandProperty OwningProcess -Unique)
    throw "Port $Port is already in use by process ID(s): $($ownerIds -join ', '). Close that application and run this script again."
}

New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$stdoutLog = Join-Path $logDirectory "llama-server-$timestamp.out.log"
$stderrLog = Join-Path $logDirectory "llama-server-$timestamp.err.log"
$serverArguments = @(
    "--model", ('"{0}"' -f $modelPath),
    "--alias", $modelAlias,
    "--host", "127.0.0.1",
    "--port", [string]$Port,
    "--ctx-size", "65536",
    "--parallel", "1",
    "--gpu-layers", "all",
    "--flash-attn", "auto",
    "--jinja",
    "--cors-origins", "localhost",
    "--no-webui"
)

Write-Host "Starting local Gemma 4 server on the Intel GPU..." -ForegroundColor Cyan
$serverProcess = $null
$serverReady = $false
try {
$serverProcess = Start-Process `
    -FilePath $serverExe `
    -ArgumentList $serverArguments `
    -WorkingDirectory $workshopRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog `
    -PassThru

Write-AtomicTextFile -LiteralPath $pidFile -Content ([string]$serverProcess.Id)
@{
    process_id = $serverProcess.Id
    executable = $serverExe
    model = $modelPath
    alias = $modelAlias
    started_at = (Get-Date).ToString("o")
    stdout_log = $stdoutLog
    stderr_log = $stderrLog
} | ConvertTo-Json | ForEach-Object { Write-AtomicTextFile -LiteralPath $serverInfoFile -Content $_ }

$deadline = (Get-Date).AddSeconds($WaitSeconds)
do {
    if ($serverProcess.HasExited) {
        $details = if (Test-Path -LiteralPath $stderrLog) {
            (Get-Content -LiteralPath $stderrLog -Tail 30) -join [Environment]::NewLine
        }
        else {
            "No server error log was created."
        }
        throw "llama-server exited before becoming ready.`n$details"
    }

    if (Test-WorkshopEndpoint) {
        $serverReady = $true
        Write-Host "[OK] Local Gemma 4 endpoint is ready: http://127.0.0.1:$Port/v1" -ForegroundColor Green
        Write-Host "[OK] llama-server process ID: $($serverProcess.Id)" -ForegroundColor Green
        return
    }

    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)

throw "Timed out waiting for Gemma 4. Review: $stderrLog"
}
finally {
    if ($null -ne $serverProcess -and -not $serverReady -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
    }
}
