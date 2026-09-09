#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$SkipHermesInstall,
    [switch]$ForceModelDownload,
    [switch]$DoNotStartServer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$packageName = "hermes-llamacpp-gemma4-workshop-windows-x64-intel-vulkan-v0.3.0"
$payloadRoot = Join-Path $PSScriptRoot "payload"
$installRoot = Join-Path $env:USERPROFILE "Hermes-Local-Workshop\$packageName"
$logDirectory = Join-Path $installRoot "logs"
$modelDirectory = Join-Path $installRoot "models"
$practiceDirectory = Join-Path $installRoot "hermes-practice"
$modelPath = Join-Path $modelDirectory "gemma-4-26B_q4_0-it.gguf"
$modelPartialPath = "$modelPath.partial"
$expectedModelSha = "3ECA3B8F6D7BAF218A7DD6BBA5FB59A56EE25FE2D567B6F5F589B4F697ECA51D"
$modelUrl = "https://huggingface.co/google/gemma-4-26B-A4B-it-qat-q4_0-gguf/resolve/8afd43710afbb87c711f33f7e7c11b1434a9fa1a/gemma-4-26B_q4_0-it.gguf?download=true"
$installerUrl = "https://hermes-agent.nousresearch.com/install.ps1"
$installerPath = Join-Path $env:TEMP "hermes-install.ps1"
$transcriptStarted = $false

function Write-Step {
    param([int]$Number, [string]$Message)
    Write-Host ""
    Write-Host "[$Number/6] $Message" -ForegroundColor Cyan
}

function Receive-WorkshopDownload {
    param([string]$Uri, [string]$Destination)
    # Windows PowerShell/.NET uses the Windows proxy and certificate settings.
    # Stream to disk; never buffer the multi-GB model in memory.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $response = $null
        $inputStream = $null
        $outputStream = $null
        try {
            $offset = 0L
            if (Test-Path -LiteralPath $Destination) { $offset = (Get-Item -LiteralPath $Destination).Length }
            $request = [Net.HttpWebRequest]::Create($Uri)
            $request.Timeout = 30000
            $request.ReadWriteTimeout = 60000
            if ($offset -gt 0) { $request.AddRange($offset) }
            $response = $request.GetResponse()
            $mode = [IO.FileMode]::Create
            if ([int]$response.StatusCode -eq 206) {
                if ($response.Headers['Content-Range'] -notmatch "^bytes $offset-") { throw 'Server returned an unexpected resume offset.' }
                $mode = [IO.FileMode]::Append
            }
            $inputStream = $response.GetResponseStream()
            $outputStream = [IO.File]::Open($Destination, $mode, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $buffer = New-Object byte[] (1MB)
            $received = 0L
            $lastUpdate = [DateTime]::UtcNow
            while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $outputStream.Write($buffer, 0, $count)
                $received += $count
                if (([DateTime]::UtcNow - $lastUpdate).TotalSeconds -ge 30) {
                    Write-Host ('  - Downloaded {0:N2} GB' -f ($outputStream.Length / 1GB))
                    $lastUpdate = [DateTime]::UtcNow
                }
            }
            if ($response.ContentLength -ge 0 -and $received -ne $response.ContentLength) { throw 'Download ended before all bytes arrived.' }
            return
        }
        catch {
            if ($attempt -eq 3) {
                throw "Download failed after three Windows HTTPS attempts. Partial data is preserved. Check access to Hugging Face and its download CDN on this network. Details: $($_.Exception.Message)"
            }
            Write-Host "  - Windows HTTPS connection interrupted; retrying ($attempt/3)."
        }
        finally {
            if ($outputStream) { $outputStream.Dispose() }
            if ($inputStream) { $inputStream.Dispose() }
            if ($response) { $response.Dispose() }
        }
        Start-Sleep -Seconds 3
    }
}

function Assert-LastExitCode {
    param([string]$Operation)
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

function Invoke-NativeCommandCapture {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )

    # Windows PowerShell 5.1 converts native stderr into ErrorRecord objects
    # when stderr is merged with stdout. Some successful tools, including
    # llama-server --version, intentionally write normal output to stderr.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $capturedItems = @(& $FilePath @ArgumentList 2>&1)
        $nativeExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $capturedText = @($capturedItems | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    return [pscustomobject]@{
        ExitCode = $nativeExitCode
        Text = $capturedText
    }
}

function Invoke-HermesInstaller {
    param([string]$Label, [string[]]$InstallerArguments)
    $childPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    Write-Host "  - $Label"
    & $childPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installerPath @InstallerArguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE."
    }
}

function Find-HermesLauncher {
    $hermesBin = Join-Path $env:LOCALAPPDATA "hermes\bin"
    $launcher = Get-ChildItem -LiteralPath $hermesBin -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @("hermes.exe", "hermes.cmd") } |
        Select-Object -First 1
    if ($null -eq $launcher) {
        throw "Hermes launcher was not found under $hermesBin."
    }
    return $launcher.FullName
}

function Invoke-Hermes {
    param([string]$Launcher, [string[]]$HermesArguments)
    $result = Invoke-NativeCommandCapture -FilePath $Launcher -ArgumentList $HermesArguments
    if ($result.ExitCode -ne 0) {
        throw "Hermes command failed: hermes $($HermesArguments -join ' ')`n$($result.Text)"
    }
    return $result.Text
}

function Get-Sha256Hash {
    # Avoids depending on the Get-FileHash cmdlet, which can be missing if
    # Microsoft.PowerShell.Utility fails to autoload in a locked-down environment.
    param([string]$LiteralPath)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fileStream = [IO.File]::OpenRead($LiteralPath)
        try {
            $hashBytes = $sha256.ComputeHash($fileStream)
        }
        finally { $fileStream.Dispose() }
    }
    finally { $sha256.Dispose() }
    return [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToUpperInvariant()
}

function Get-HttpStatusCode {
    param($ErrorRecord)
    $response = $ErrorRecord.Exception.Response
    if ($response -and $response.StatusCode) { return [int]$response.StatusCode }
    return $null
}

function Get-HttpRetryAfterSeconds {
    # Works for both Windows PowerShell's WebException and PowerShell 7's HttpResponseException.
    param($ErrorRecord)
    $response = $ErrorRecord.Exception.Response
    if (-not $response) { return $null }
    try {
        $retryAfterValues = $null
        if ($response.Headers -is [System.Net.Http.Headers.HttpResponseHeaders]) {
            if ($response.Headers.RetryAfter -and $response.Headers.RetryAfter.Delta) {
                return [int]$response.Headers.RetryAfter.Delta.Value.TotalSeconds
            }
        }
        else {
            $retryAfterValues = $response.Headers["Retry-After"]
        }
        if ($retryAfterValues) {
            $parsedSeconds = 0
            if ([int]::TryParse(@($retryAfterValues)[0], [ref]$parsedSeconds)) { return $parsedSeconds }
        }
    }
    catch { }
    return $null
}

function Invoke-DownloadWithRetry {
    param([string]$Uri, [string]$OutFile, [int]$MaxAttempts = 6)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
            return
        }
        catch {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            if ($attempt -eq $MaxAttempts) { throw }
            $statusCode = Get-HttpStatusCode $_
            $retryAfterSeconds = Get-HttpRetryAfterSeconds $_
            if ($statusCode -eq 429) {
                # Rate limits can require a longer cooldown than a simple backoff.
                $retryDelay = if ($retryAfterSeconds) { $retryAfterSeconds } else { 30 * $attempt }
                Write-Warning "Download attempt $attempt of $MaxAttempts was rate limited (HTTP 429). Retrying in $retryDelay seconds."
            }
            else {
                $retryDelay = 5 * $attempt
                Write-Warning "Download attempt $attempt of $MaxAttempts failed ($($_.Exception.Message)). Retrying in $retryDelay seconds."
            }
            Start-Sleep -Seconds $retryDelay
        }
    }
}

function Test-UvInstalled {
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        Write-Host "  - uv (astral-sh) found" -ForegroundColor Green
        return
    }
    Write-Warning "uv (astral-sh.uv) was not found on PATH; installing via winget..."
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "uv is required but not installed, and winget is not available to install it automatically. Install uv manually: https://docs.astral.sh/uv/getting-started/installation/"
    }
    winget install --id astral-sh.uv --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget install astral-sh.uv failed with exit code $LASTEXITCODE."
    }
    # Refresh PATH from the registry so this process can see the newly installed uv.exe.
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "User") + ";" + [Environment]::GetEnvironmentVariable("Path", "Machine")
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        throw "uv was installed via winget but is not on PATH in this session. Open a new terminal and re-run setup."
    }
    Write-Host "  - uv installed via winget" -ForegroundColor Green
}

# HKCU\Environment is read and written unexpanded: [Environment]::SetEnvironmentVariable
# rewrites PATH as REG_SZ, permanently baking out any %VAR% references it contains.
function Add-UserPathEntry {
    param([string]$Directory)
    $environmentKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
    if ($null -eq $environmentKey) {
        throw "The user environment registry key (HKCU\Environment) could not be opened."
    }
    try {
        $existingValue = [string]$environmentKey.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $existingEntries = @($existingValue -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($existingEntries -contains $Directory) { return }
        $valueKind = if (@($environmentKey.GetValueNames()) -contains "Path") {
            $environmentKey.GetValueKind("Path")
        }
        else {
            [Microsoft.Win32.RegistryValueKind]::ExpandString
        }
        $environmentKey.SetValue("Path", ((@($Directory) + $existingEntries) -join ";"), $valueKind)
    }
    finally {
        $environmentKey.Dispose()
    }
}

function Test-HasInteractiveConsole {
    try {
        return (
            [Environment]::UserInteractive `
            -and (-not [Console]::IsInputRedirected) `
            -and (-not [Console]::IsOutputRedirected) `
            -and ($Host.Name -eq "ConsoleHost")
        )
    }
    catch { return $false }
}

function Confirm-ModelDownload {
    if (-not (Test-HasInteractiveConsole)) { return $true }
    Write-Host ""
    Write-Host "Gemma 4 has not finished downloading yet." -ForegroundColor Yellow
    Write-Host "Continuing will begin a large (multi-GB) download from Hugging Face." -ForegroundColor Yellow
    $response = Read-Host "Begin the model download now? [Y/n]"
    return ($response -eq "" -or $response -match "^[Yy]")
}

try {
    if ($env:OS -ne "Windows_NT") {
        throw "This workshop package supports Windows only."
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw "A 64-bit Windows operating system is required."
    }
    if (-not (Test-Path -LiteralPath $payloadRoot)) {
        throw "The payload folder is missing. Extract the complete easy-installation ZIP and run setup again."
    }

    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $transcriptPath = Join-Path $logDirectory ("easy-install-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
    $transcriptStarted = $true

    Write-Host "==============================================================" -ForegroundColor Blue
    Write-Host " HERMES + LOCAL GEMMA 4 - EASY WORKSHOP SETUP" -ForegroundColor White
    Write-Host "==============================================================" -ForegroundColor Blue
    Write-Host "Installation folder: $installRoot"
    Write-Host "Log file: $transcriptPath"

    Write-Step 1 "Verify this computer and the precompiled llama.cpp payload"
    $gpuControllers = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion)
    $intelControllers = @($gpuControllers | Where-Object { $_.Name -match "Intel" })
    if ($intelControllers.Count -eq 0) {
        throw "No Intel GPU was detected. This package is intended for Intel GPU workshop systems."
    }
    $gpuControllers | Format-Table -AutoSize | Out-Host

    $vulkanLoader = Join-Path $env:WINDIR "System32\vulkan-1.dll"
    if (-not (Test-Path -LiteralPath $vulkanLoader)) {
        throw "The Vulkan runtime was not found. Install the IT-approved Intel graphics driver, reboot, and retry. The Vulkan SDK is not required."
    }
    Test-UvInstalled

    $payloadSums = Join-Path $payloadRoot "SHA256SUMS.txt"
    if (-not (Test-Path -LiteralPath $payloadSums)) {
        throw "Payload checksum file is missing: $payloadSums"
    }
    foreach ($checksumLine in Get-Content -LiteralPath $payloadSums) {
        if ([string]::IsNullOrWhiteSpace($checksumLine)) { continue }
        if ($checksumLine -notmatch "^([0-9a-fA-F]{64})\s{2}(.+)$") {
            throw "Invalid checksum entry: $checksumLine"
        }
        $expectedPayloadSha = $Matches[1].ToUpperInvariant()
        $relativePayloadPath = $Matches[2].Replace("/", "\")
        $payloadFile = Join-Path $payloadRoot $relativePayloadPath
        if (-not (Test-Path -LiteralPath $payloadFile)) {
            throw "Payload file is missing: $relativePayloadPath"
        }
        $actualPayloadSha = Get-Sha256Hash -LiteralPath $payloadFile
        if ($actualPayloadSha -ne $expectedPayloadSha) {
            throw "Payload checksum mismatch: $relativePayloadPath"
        }
    }
    Write-Host "[OK] Packaged files passed SHA-256 verification." -ForegroundColor Green

    Get-ChildItem -LiteralPath $payloadRoot -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $installRoot -Recurse -Force
    }

    $serverExe = Join-Path $installRoot "bin\llama-server.exe"
    $serverVersionResult = Invoke-NativeCommandCapture -FilePath $serverExe -ArgumentList @("--version")
    if ($serverVersionResult.ExitCode -ne 0) {
        throw "llama-server version check failed with exit code $($serverVersionResult.ExitCode).`n$($serverVersionResult.Text)"
    }
    $serverVersion = $serverVersionResult.Text.Trim()
    if ($serverVersion -notmatch "0\.3\.0" -or $serverVersion -notmatch "c1d0e7a" -or $serverVersion -notmatch "x64") {
        throw "The copied llama.cpp runtime did not report the expected version, commit, and architecture.`n$serverVersion"
    }
    $deviceListResult = Invoke-NativeCommandCapture -FilePath $serverExe -ArgumentList @("--list-devices")
    if ($deviceListResult.ExitCode -ne 0) {
        throw "llama-server device check failed with exit code $($deviceListResult.ExitCode).`n$($deviceListResult.Text)"
    }
    $deviceList = $deviceListResult.Text.Trim()
    if ($deviceList -notmatch "(?i)Vulkan\d+:.*Intel") {
        throw "llama.cpp could not find an Intel Vulkan device.`n$deviceList"
    }
    Write-Host $serverVersion
    Write-Host $deviceList
    Write-Host "[OK] Precompiled llama.cpp can access the Intel GPU through Vulkan." -ForegroundColor Green

    Write-Step 2 "Install and verify Hermes Agent"
    if (-not $SkipHermesInstall) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-DownloadWithRetry -Uri $installerUrl -OutFile $installerPath
        if ((Get-Item -LiteralPath $installerPath).Length -lt 10000) {
            throw "The downloaded Hermes installer is unexpectedly small."
        }

        # Single, non-interactive install -- equivalent to the official
        # `iex (irm https://hermes-agent.nousresearch.com/install.ps1)` one-liner.
        Invoke-HermesInstaller "Installing Hermes Agent" @("-SkipSetup", "-NonInteractive")
    }
    else {
        Write-Host "Hermes installation was skipped by request. Existing installation will be validated."
    }

    $hermesBin = Join-Path $env:LOCALAPPDATA "hermes\bin"
    $pathEntries = @($env:Path -split ";")
    if ($pathEntries -notcontains $hermesBin) {
        $env:Path = "$hermesBin;$env:Path"
    }
    Add-UserPathEntry -Directory $hermesBin

    $hermesLauncher = Find-HermesLauncher
    $hermesVersion = (Invoke-Hermes $hermesLauncher @("--version") | Out-String).Trim()
    Write-Host $hermesVersion
    Write-Host "[OK] Hermes Agent is installed." -ForegroundColor Green

    Write-Step 3 "Download and verify Gemma 4"
    New-Item -ItemType Directory -Path $modelDirectory -Force | Out-Null
    $validModelExists = $false
    if (Test-Path -LiteralPath $modelPath) {
        $existingModelSha = Get-Sha256Hash -LiteralPath $modelPath
        $validModelExists = ($existingModelSha -eq $expectedModelSha)
    }
    if ($ForceModelDownload) { $validModelExists = $false }

    if (-not $validModelExists) {
        if (-not (Confirm-ModelDownload)) {
            throw "Model download declined. Run this installer again when ready to download Gemma 4."
        }
        if (Test-Path -LiteralPath $modelPath) {
            $invalidModelPath = "$modelPath.invalid-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Move-Item -LiteralPath $modelPath -Destination $invalidModelPath
            Write-Warning "An invalid model file was preserved as: $invalidModelPath"
        }

        $installDriveName = ([IO.Path]::GetPathRoot($installRoot)).TrimEnd("\").TrimEnd(":")
        $installDrive = Get-PSDrive -Name $installDriveName
        if ($installDrive.Free -lt 20GB) {
            throw "At least 20 GB of free disk space is required before downloading Gemma 4."
        }

        $curlCommand = Get-Command curl.exe -ErrorAction SilentlyContinue
        if ($curlCommand) {
            & $curlCommand.Source -L --fail --connect-timeout 30 --speed-limit 1024 --speed-time 60 --retry 2 --retry-delay 3 -C - -o $modelPartialPath $modelUrl
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  - curl could not finish; switching to Windows HTTPS with resume support."
                Receive-WorkshopDownload -Uri $modelUrl -Destination $modelPartialPath
            }
        }
        else {
            Receive-WorkshopDownload -Uri $modelUrl -Destination $modelPartialPath
        }

        $downloadedModelSha = Get-Sha256Hash -LiteralPath $modelPartialPath
        if ($downloadedModelSha -ne $expectedModelSha) {
            throw "Gemma 4 checksum verification failed. The partial file was kept at $modelPartialPath."
        }
        Move-Item -LiteralPath $modelPartialPath -Destination $modelPath -Force
    }

    $verifiedModelSha = Get-Sha256Hash -LiteralPath $modelPath
    if ($verifiedModelSha -ne $expectedModelSha) {
        throw "Gemma 4 checksum verification failed after installation."
    }
    $modelSizeGb = [math]::Round((Get-Item -LiteralPath $modelPath).Length / 1GB, 3)
    Write-Host "[OK] Gemma 4 verified ($modelSizeGb GB)." -ForegroundColor Green

    Write-Step 4 "Start Gemma 4 with llama.cpp on the Intel GPU"
    $startScript = Join-Path $installRoot "Start-HermesLocalWorkshop.ps1"
    if (-not $DoNotStartServer) {
        & $startScript
    }
    else {
        Write-Host "Server start was skipped by request."
    }

    Write-Step 5 "Test the local OpenAI-compatible API"
    if ($DoNotStartServer) {
        Write-Host "API test skipped because -DoNotStartServer was selected."
    }
    else {
        $chatBody = @{
            model = "gemma-4-26b-a4b-local"
            messages = @(@{ role = "user"; content = "Reply with exactly: LOCAL GEMMA READY" })
            temperature = 0
            max_tokens = 128
        } | ConvertTo-Json -Depth 6
        $chatResponse = Invoke-RestMethod `
            -Uri "http://127.0.0.1:8080/v1/chat/completions" `
            -Method Post `
            -ContentType "application/json" `
            -Body $chatBody `
            -TimeoutSec 120
        $chatContent = [string]$chatResponse.choices[0].message.content
        if ($chatContent -notmatch "LOCAL GEMMA READY") {
            throw "The API responded, but the expected local-model validation text was absent: $chatContent"
        }
        Write-Host "[OK] Local chat completion returned: $chatContent" -ForegroundColor Green
    }

    Write-Step 6 "Connect Hermes to the local Gemma 4 endpoint"
    $hermesConfig = Join-Path $env:LOCALAPPDATA "hermes\config.yaml"
    if (Test-Path -LiteralPath $hermesConfig) {
        $configBackup = "$hermesConfig.before-easy-workshop-$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
        Copy-Item -LiteralPath $hermesConfig -Destination $configBackup -Force
        Write-Host "Existing Hermes configuration backed up to: $configBackup"
    }

    Invoke-Hermes $hermesLauncher @("config", "set", "model.provider", "custom") | Out-Host
    Invoke-Hermes $hermesLauncher @("config", "set", "model.base_url", "http://127.0.0.1:8080/v1") | Out-Host
    Invoke-Hermes $hermesLauncher @("config", "set", "model.default", "gemma-4-26b-a4b-local") | Out-Host

    $providerValue = (Invoke-Hermes $hermesLauncher @("config", "get", "model.provider") | Out-String).Trim()
    $baseUrlValue = (Invoke-Hermes $hermesLauncher @("config", "get", "model.base_url") | Out-String).Trim()
    $modelValue = (Invoke-Hermes $hermesLauncher @("config", "get", "model.default") | Out-String).Trim()
    if ($providerValue -notmatch "custom" -or
        $baseUrlValue -notmatch "http://127\.0\.0\.1:8080/v1" -or
        $modelValue -notmatch "gemma-4-26b-a4b-local") {
        throw "Hermes configuration verification failed.`nProvider: $providerValue`nBase URL: $baseUrlValue`nModel: $modelValue"
    }

    New-Item -ItemType Directory -Path $practiceDirectory -Force | Out-Null
    $readyFile = Join-Path $installRoot "WORKSHOP_READY.txt"
    @(
        "WORKSHOP READY"
        "Prepared: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')"
        "Hermes: $hermesVersion"
        "Model: gemma-4-26b-a4b-local"
        "Endpoint: http://127.0.0.1:8080/v1"
        "Model SHA-256: $verifiedModelSha"
        "Practice directory: $practiceDirectory"
        "Exercises: $(Join-Path $installRoot 'TASKS.md')"
    ) | Set-Content -LiteralPath $readyFile -Encoding UTF8

    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Green
    Write-Host " WORKSHOP READY" -ForegroundColor Green
    Write-Host "==============================================================" -ForegroundColor Green
    Write-Host "Local model: gemma-4-26b-a4b-local"
    Write-Host "Endpoint: http://127.0.0.1:8080/v1"
    Write-Host "Exercises: $(Join-Path $installRoot 'TASKS.md')"
    Write-Host "Practice directory: $practiceDirectory"
    Write-Host ""
    Write-Host "Start Hermes now by entering:" -ForegroundColor Yellow
    Write-Host "  hermes" -ForegroundColor White
    Write-Host "Open the exercises with:" -ForegroundColor Yellow
    Write-Host "  Invoke-Item '..\TASKS.md'" -ForegroundColor White
    Set-Location -LiteralPath $practiceDirectory
}
catch {
    Write-Host ""
    Write-Host "SETUP STOPPED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Correct the reported prerequisite or network issue, then run the same setup again." -ForegroundColor Yellow
    throw
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}
