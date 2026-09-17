#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Model,

    # Generous default: these models are 5-20+ GB, and workshop networks vary widely
    [ValidateRange(30, 10800)]
    [int]$WaitSeconds = 2700,

    [ValidateRange(1024, 65535)]
    [int]$Port = 8000,

    [switch]$SkipHermesInstall,
    [switch]$DoNotStartServer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$packageName = "hermes-ovms-workshop-windows-x64-intel-v1.0.0"
$installRoot = Join-Path $env:USERPROFILE "OVMS-Local-Workshop\$packageName"
$logDirectory = Join-Path $installRoot "logs"
$ovmsDir = Join-Path $installRoot "ovms"
$ovmsExe = Join-Path $ovmsDir "ovms.exe"
$stateDirectory = Join-Path $installRoot ".state"
$modelStatePath = Join-Path $stateDirectory "selected-model.json"
$modelConfigPath = Join-Path $PSScriptRoot "model-config.json"
$ovmsLatestReleaseUrl = "https://github.com/openvinotoolkit/model_server/releases/latest"
$ovmsVersion = $null
$ovmsUrl = $null
$ovmsExpectedSha256 = $null
$ovmsZipPath = $null
$ovmsVersionPath = Join-Path $stateDirectory "ovms-version.txt"
$installerUrl = "https://hermes-agent.nousresearch.com/install.ps1"
$installerPath = Join-Path $env:TEMP "hermes-install.ps1"
$transcriptStarted = $false

if (-not (Test-Path -LiteralPath $modelConfigPath)) {
    throw "Model configuration is missing: $modelConfigPath"
}
$modelConfigs = Get-Content -LiteralPath $modelConfigPath -Raw | ConvertFrom-Json
$savedModel = $null
if ([string]::IsNullOrWhiteSpace($Model) -and (Test-Path -LiteralPath $modelStatePath)) {
    try { $savedModel = (Get-Content -LiteralPath $modelStatePath -Raw | ConvertFrom-Json).model }
    catch { Write-Warning "Saved model state could not be read; using the default model." }
}
if ([string]::IsNullOrWhiteSpace($Model)) { $Model = if ($savedModel) { $savedModel } else { "qwen3.8-27b" } }
if (@($modelConfigs.PSObject.Properties.Name) -notcontains $Model) {
    throw "Unsupported model '$Model'. Choose one of: $($modelConfigs.PSObject.Properties.Name -join ', ')"
}
$selectedModel = $modelConfigs.$Model
# The API exposes the model under its short name (e.g. Qwen3.5-27B-int4-ov), without the publisher prefix
$modelAlias = ($selectedModel.SourceModel -split "/")[-1]

function Write-Step {
    param([int]$Number, [string]$Message)
    Write-Host ""
    Write-Host "[$Number/6] $Message" -ForegroundColor Cyan
}

function Get-OVMSAssetDigest {
    param([string]$AssetName)
    return $ovmsExpectedSha256
}

function Test-FreeDiskSpace {
    $pathRoot = [IO.Path]::GetPathRoot($installRoot)
    if ($pathRoot -notmatch '^[A-Za-z]:\\$') {
        Write-Warning "Free space cannot be checked for a non-local install root ($pathRoot); make sure at least 40 GB is available."
        return
    }
    $driveName = $pathRoot.Substring(0, 1)
    $drive = Get-PSDrive -Name $driveName -ErrorAction Stop
    $requiredBytes = 40GB
    if ($drive.Free -lt $requiredBytes) {
        $freeGb = [math]::Round($drive.Free / 1GB, 1)
        throw "At least 40 GB of free space is required on drive $driveName`: (currently $freeGb GB available)."
    }
    Write-Host "  - Free disk space: $([math]::Round($drive.Free / 1GB, 1)) GB"
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
    return [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant()
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

function Get-HttpStatusCode {
    param($ErrorRecord)
    $response = $ErrorRecord.Exception.Response
    if ($response -and $response.StatusCode) { return [int]$response.StatusCode }
    return $null
}

function Invoke-DownloadWithRetry {
    param([string]$Uri, [string]$OutFile, [int]$MaxAttempts = 6)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $requestHeaders = @{ "User-Agent" = "Windows-Local-Workshop-Installer/$ovmsVersion" }
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Invoke-WebRequest `
                -Uri $Uri `
                -OutFile $OutFile `
                -Headers $requestHeaders `
                -TimeoutSec 120 `
                -UseBasicParsing
            return
        }
        catch {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            $statusCode = Get-HttpStatusCode $_
            $retryableStatusCodes = @(408, 425, 429, 500, 502, 503, 504)
            if ($statusCode -and $statusCode -notin $retryableStatusCodes) {
                throw "Download failed with HTTP ${statusCode}: $Uri`n$($_.Exception.Message)"
            }
            if ($attempt -eq $MaxAttempts) { throw }
            $retryAfterSeconds = Get-HttpRetryAfterSeconds $_
            if ($statusCode -eq 429) {
                # GitHub rate limits can require a longer cooldown than a simple backoff.
                $retryDelay = if ($retryAfterSeconds) { [math]::Min($retryAfterSeconds, 300) } else { 30 * $attempt }
                Write-Warning "Download attempt $attempt of $MaxAttempts was rate limited (HTTP 429). Retrying in $retryDelay seconds."
            }
            else {
                $retryDelay = [math]::Min(5 * $attempt, 30)
                Write-Warning "Download attempt $attempt of $MaxAttempts failed ($($_.Exception.Message)). Retrying in $retryDelay seconds."
            }
            Start-Sleep -Seconds $retryDelay
        }
    }
}

function Resolve-OVMSRelease {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $latestLocation = $null
    $response = $null
    $request = [Net.HttpWebRequest]::Create($ovmsLatestReleaseUrl)
    $request.Method = "HEAD"
    $request.AllowAutoRedirect = $false
    $request.UserAgent = "Windows-Local-Workshop-Installer/latest"
    try {
        $response = $request.GetResponse()
        $latestLocation = $response.Headers["Location"]
    }
    catch {
        if ($_.Exception.Response) { $latestLocation = $_.Exception.Response.Headers["Location"] }
    }
    finally {
        if ($response) { $response.Dispose() }
    }
    if ([string]::IsNullOrWhiteSpace($latestLocation)) {
        throw "Could not resolve the latest OVMS release from GitHub."
    }
    $tag = ([Uri]$latestLocation).Segments[-1]
    if ($tag -notmatch '^v(\d+\.\d+\.\d+)$') {
        throw "GitHub returned an unexpected latest OVMS release location: $latestLocation"
    }
    $version = $Matches[1]
    $assetName = "ovms_windows_${version}_python_on.zip"
    $assetUrl = "https://github.com/openvinotoolkit/model_server/releases/download/v$version/$assetName"
    $checksumUrl = "$assetUrl.sha256"
    try {
        $checksumText = (Invoke-WebRequest -Uri $checksumUrl -Headers @{ "User-Agent" = "Windows-Local-Workshop-Installer/$version" } -TimeoutSec 30 -UseBasicParsing).Content
        if ($checksumText -notmatch '(?i)\b([0-9a-f]{64})\b') { throw "No SHA-256 digest was found." }
        $digest = $Matches[1]
    }
    catch {
        throw "Could not retrieve the checksum for ${assetName}: $($_.Exception.Message)"
    }
    return [pscustomobject]@{
        Version = $version
        Url = $assetUrl
        Sha256 = $digest.ToLowerInvariant()
    }
}

function Test-ExternalDownloadEndpoint {
    param([string]$Name, [string]$Uri)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        Invoke-WebRequest `
            -Uri $Uri `
            -Method Head `
            -Headers @{ "User-Agent" = "Windows-Local-Workshop-Installer/$ovmsVersion" } `
            -TimeoutSec 20 `
            -MaximumRedirection 5 `
            -UseBasicParsing | Out-Null
        Write-Host "  - ${Name}: reachable" -ForegroundColor Green
        return $true
    }
    catch {
        # A 405 still proves that DNS, TLS, and the proxy reached the server.
        $statusCode = Get-HttpStatusCode $_
        if ($statusCode -eq 405) {
            Write-Host "  - ${Name}: reachable (HEAD not supported)" -ForegroundColor Green
            return $true
        }
        Write-Warning "$Name could not be reached before download (HTTP $statusCode): $($_.Exception.Message)"
        return $false
    }
}

function Test-WorkshopNetwork {
    $checks = @(
        @{ Name = "GitHub release host"; Uri = $ovmsUrl }
        @{ Name = "Hermes installer host"; Uri = $installerUrl }
        @{ Name = "Hugging Face model host"; Uri = "https://huggingface.co/$($selectedModel.SourceModel)" }
    )
    $failedChecks = @($checks | Where-Object { -not (Test-ExternalDownloadEndpoint -Name $_.Name -Uri $_.Uri) })
    if ($failedChecks.Count -gt 0) {
        Write-Warning "One or more external endpoints failed the preflight. The installer will continue and retry downloads, but a proxy or firewall rule may need attention."
    }
}

function Invoke-NativeCommandCapture {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )
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
    return [pscustomobject]@{ ExitCode = $nativeExitCode; Text = $capturedText }
}

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
    param([string]$ModelName, [string]$SourceModel)
    if (-not (Test-HasInteractiveConsole)) { return $true }
    Write-Host ""
    Write-Host "Model $ModelName ($SourceModel) has not finished downloading yet." -ForegroundColor Yellow
    Write-Host "Starting the server now will begin a large (multi-GB) download from Hugging Face." -ForegroundColor Yellow
    $response = Read-Host "Start the server and begin the model download now? [Y/n]"
    return ($response -eq "" -or $response -match "^[Yy]")
}

function Invoke-Hermes {
    param([string]$Launcher, [string[]]$HermesArguments)
    $result = Invoke-NativeCommandCapture -FilePath $Launcher -ArgumentList $HermesArguments
    if ($result.ExitCode -ne 0) {
        throw "Hermes command failed: hermes $($HermesArguments -join ' ')`n$($result.Text)"
    }
    return $result.Text
}

try {
    if ($env:OS -ne "Windows_NT") {
        throw "This workshop package supports Windows only."
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw "A 64-bit Windows operating system is required."
    }

    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $transcriptPath = Join-Path $logDirectory ("easy-install-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
    $transcriptStarted = $true

    # Start/Stop scripts must live in installRoot so their own $PSScriptRoot-relative
    # paths (ovms\ovms.exe, models\, .ovcache\, .state\) resolve to the real install location
    foreach ($scriptName in @("Start-OVMSLocalWorkshop.ps1", "Stop-OVMSLocalWorkshop.ps1", "model-config.json")) {
        $sourceFile = Join-Path $PSScriptRoot $scriptName
        $destinationFile = Join-Path $installRoot $scriptName
        if ([IO.Path]::GetFullPath($sourceFile) -ne [IO.Path]::GetFullPath($destinationFile)) {
            Copy-Item -LiteralPath $sourceFile -Destination $destinationFile -Force
        }
    }

    Write-Host "==============================================================" -ForegroundColor Blue
    Write-Host " HERMES + OVMS - EASY WORKSHOP SETUP" -ForegroundColor White
    Write-Host "==============================================================" -ForegroundColor Blue
    Write-Host "Model: $Model ($($selectedModel.SourceModel))"
    Write-Host "Installation folder: $installRoot"
    Write-Host "Log file: $transcriptPath"

    Write-Step 1 "Verify this computer"
    Test-FreeDiskSpace
    Test-UvInstalled
    $gpuControllers = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion)
    $gpuControllers | Format-Table -AutoSize | Out-Host
    $intelControllers = @($gpuControllers | Where-Object { $_.Name -match "Intel" })
    if ($intelControllers.Count -eq 0) {
        Write-Warning "No Intel GPU was detected. OVMS will still run, but on CPU only (slower)."
    }
    # No Vulkan SDK or manual Git install is required: OVMS ships as a
    # self-contained prebuilt zip, and the official Hermes installer provisions
    # its own portable Git automatically in the next step. System-wide uv is
    # verified above since this script relies on it being on PATH.

    $release = Resolve-OVMSRelease
    $ovmsVersion = $release.Version
    $ovmsUrl = $release.Url
    $ovmsExpectedSha256 = $release.Sha256
    $ovmsZipPath = Join-Path $env:TEMP "ovms-$ovmsVersion.zip"
    $installedOvmsVersion = if (Test-Path -LiteralPath $ovmsVersionPath) { (Get-Content -LiteralPath $ovmsVersionPath -Raw).Trim() } else { $null }
    Write-Step 2 "Download and extract OVMS $ovmsVersion"
    Test-WorkshopNetwork
    if ((Test-Path -LiteralPath $ovmsExe) -and $installedOvmsVersion -eq $ovmsVersion) {
        Write-Host "[OK] OVMS is already installed at $ovmsExe" -ForegroundColor Green
    }
    else {
        if (Test-Path -LiteralPath $ovmsExe) {
            Write-Host "[INFO] Updating OVMS from $installedOvmsVersion to $ovmsVersion." -ForegroundColor Yellow
        }
        Invoke-DownloadWithRetry -Uri $ovmsUrl -OutFile $ovmsZipPath
        $expectedDigest = Get-OVMSAssetDigest ([IO.Path]::GetFileName($ovmsUrl))
        $actualDigest = Get-Sha256Hash -LiteralPath $ovmsZipPath
        if ($actualDigest -ne $expectedDigest.ToLowerInvariant()) {
            Remove-Item -LiteralPath $ovmsZipPath -Force -ErrorAction SilentlyContinue
            throw "OVMS download failed SHA-256 verification. Expected $expectedDigest, got $actualDigest."
        }
        $extractRoot = Join-Path $installRoot ".ovms-extract-$PID"
        $stagedOvmsDir = Join-Path $extractRoot "ovms"
        $previousOvmsDir = Join-Path $installRoot "ovms.previous-$PID"
        try {
            Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
            Expand-Archive -Path $ovmsZipPath -DestinationPath $extractRoot -Force
            if (-not (Test-Path -LiteralPath (Join-Path $stagedOvmsDir "ovms.exe"))) {
                throw "OVMS extraction did not produce $(Join-Path $stagedOvmsDir 'ovms.exe')."
            }

            if (Test-Path -LiteralPath $ovmsDir) {
                Move-Item -LiteralPath $ovmsDir -Destination $previousOvmsDir -Force
            }
            Move-Item -LiteralPath $stagedOvmsDir -Destination $ovmsDir -Force
            Remove-Item -LiteralPath $previousOvmsDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $ovmsZipPath -Force -ErrorAction SilentlyContinue
            Write-AtomicTextFile -LiteralPath $ovmsVersionPath -Content $ovmsVersion
        }
        catch {
            if (Test-Path -LiteralPath $previousOvmsDir) {
                Remove-Item -LiteralPath $ovmsDir -Recurse -Force -ErrorAction SilentlyContinue
                Move-Item -LiteralPath $previousOvmsDir -Destination $ovmsDir -Force -ErrorAction SilentlyContinue
            }
            throw
        }
        finally {
            Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host "[OK] OVMS $ovmsVersion extracted." -ForegroundColor Green
    }

    Write-Step 3 "Install and verify Hermes Agent"
    if (-not $SkipHermesInstall) {
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

    Write-Step 4 "Start $Model on OVMS (model downloads automatically on first run)"
    $startScript = Join-Path $installRoot "Start-OVMSLocalWorkshop.ps1"
    $modelDir = Join-Path (Join-Path $installRoot "models") $modelAlias
    $modelAlreadyDownloaded = (Test-Path -LiteralPath $modelDir) -and (Get-ChildItem -LiteralPath $modelDir -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    $skipServerStart = $DoNotStartServer
    if (-not $skipServerStart -and -not $modelAlreadyDownloaded -and -not (Confirm-ModelDownload -ModelName $Model -SourceModel $selectedModel.SourceModel)) {
        Write-Host "Model download declined. Start it later with Start-OVMSLocalWorkshop.ps1." -ForegroundColor Yellow
        $skipServerStart = $true
    }
    if (-not $skipServerStart) {
        & $startScript -Model $Model -WaitSeconds $WaitSeconds -Port $Port
    }
    else {
        # The start script records the selection when it runs; record it here when it doesn't.
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
        @{ model = $Model; source_model = $selectedModel.SourceModel; saved_at = (Get-Date).ToString("o") } |
            ConvertTo-Json | ForEach-Object { Write-AtomicTextFile -LiteralPath $modelStatePath -Content $_ }
        Write-Host "Server start was skipped by request."
    }

    Write-Step 5 "Test the local OpenAI-compatible API"
    if ($skipServerStart) {
        Write-Host "API test skipped because the server was not started."
    }
    else {
        # Informational only: the endpoint readiness check in Step 4 already proved the
        # server works, so a slow/oddly-phrased model reply here should never block setup.
        try {
            $chatBody = @{
                model = $modelAlias
                messages = @(@{ role = "user"; content = "In one short sentence, confirm you are working." })
                temperature = 0
                max_tokens = 400
            } | ConvertTo-Json -Depth 6
            $chatResponse = Invoke-RestMethod `
                -Uri "http://127.0.0.1:$Port/v1/chat/completions" `
                -Method Post `
                -ContentType "application/json" `
                -Body $chatBody `
                -TimeoutSec 180
            $chatContent = [string]$chatResponse.choices[0].message.content
            if ([string]::IsNullOrWhiteSpace($chatContent)) {
                Write-Warning "The API responded, but no answer text came back yet. This is informational only; continuing setup."
            }
            else {
                Write-Host "[OK] Local chat completion returned: $chatContent" -ForegroundColor Green
            }
        }
        catch {
            Write-Warning "API test call failed ($($_.Exception.Message)). This is informational only; continuing setup."
        }
    }

    Write-Step 6 "Connect Hermes to the local OVMS endpoint"
    $hermesConfig = Join-Path $env:LOCALAPPDATA "hermes\config.yaml"
    if (Test-Path -LiteralPath $hermesConfig) {
        $configBackup = "$hermesConfig.before-easy-workshop-$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
        Copy-Item -LiteralPath $hermesConfig -Destination $configBackup -Force
        Write-Host "Existing Hermes configuration backed up to: $configBackup"
    }

    Invoke-Hermes $hermesLauncher @("config", "set", "model.provider", "custom") | Out-Host
    Invoke-Hermes $hermesLauncher @("config", "set", "model.base_url", "http://127.0.0.1:$Port/v1") | Out-Host
    Invoke-Hermes $hermesLauncher @("config", "set", "model.default", $modelAlias) | Out-Host

    $providerValue = (Invoke-Hermes $hermesLauncher @("config", "get", "model.provider") | Out-String).Trim()
    $baseUrlValue = (Invoke-Hermes $hermesLauncher @("config", "get", "model.base_url") | Out-String).Trim()
    $modelValue = (Invoke-Hermes $hermesLauncher @("config", "get", "model.default") | Out-String).Trim()
    if ($providerValue -notmatch "custom" -or
        $baseUrlValue -notmatch [regex]::Escape("http://127.0.0.1:$Port/v1") -or
        $modelValue -notmatch [regex]::Escape($modelAlias)) {
        throw "Hermes configuration verification failed.`nProvider: $providerValue`nBase URL: $baseUrlValue`nModel: $modelValue"
    }

    $readyFile = Join-Path $installRoot "WORKSHOP_READY.txt"
    @(
        "WORKSHOP READY"
        "Prepared: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')"
        "Hermes: $hermesVersion"
        "Model: $Model ($($selectedModel.SourceModel))"
        "Endpoint: http://127.0.0.1:$Port/v1"
    ) -join [Environment]::NewLine | ForEach-Object { Write-AtomicTextFile -LiteralPath $readyFile -Content $_ }

    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Green
    Write-Host " WORKSHOP READY" -ForegroundColor Green
    Write-Host "==============================================================" -ForegroundColor Green
    Write-Host "Local model: $Model ($($selectedModel.SourceModel))"
    Write-Host "Endpoint: http://127.0.0.1:$Port/v1"
    Write-Host ""
    Write-Host "Start Hermes now by entering:" -ForegroundColor Yellow
    Write-Host "  hermes" -ForegroundColor White
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
