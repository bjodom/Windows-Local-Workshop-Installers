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
$hermesCommit = "30b83ab7b1f194503de9f5545d88c81c4db91e3f"
$installerUrl = "https://raw.githubusercontent.com/NousResearch/hermes-agent/$hermesCommit/scripts/install.ps1"
$installerPath = Join-Path $env:TEMP "hermes-install-$hermesCommit.ps1"
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

function Get-HermesGitExecutable {
    $gitCandidates = @()
    $pathGit = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($pathGit) { $gitCandidates += $pathGit.Source }
    $gitCandidates += @(
        (Join-Path $env:LOCALAPPDATA "hermes\git\cmd\git.exe"),
        (Join-Path $env:LOCALAPPDATA "hermes\git\bin\git.exe")
    )

    foreach ($gitCandidate in $gitCandidates | Select-Object -Unique) {
        if ($gitCandidate -and (Test-Path -LiteralPath $gitCandidate)) {
            return $gitCandidate
        }
    }
    throw "Git was installed by the Hermes Git stage, but git.exe could not be located."
}

function Move-HermesManagedRepositoryAside {
    param([string]$Reason)

    $hermesRoot = Join-Path $env:LOCALAPPDATA "hermes"
    $repositoryPath = Join-Path $hermesRoot "hermes-agent"
    if (-not (Test-Path -LiteralPath $repositoryPath)) { return $null }

    $resolvedHermesRoot = [IO.Path]::GetFullPath($hermesRoot).TrimEnd("\") + "\"
    $resolvedRepository = [IO.Path]::GetFullPath($repositoryPath)
    if (-not $resolvedRepository.StartsWith($resolvedHermesRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to move a repository outside the managed Hermes directory: $resolvedRepository"
    }

    $backupRoot = Join-Path $hermesRoot "backups"
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $backupPath = Join-Path $backupRoot ("hermes-agent-before-easy-workshop-{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), ([Guid]::NewGuid().ToString("N").Substring(0, 8)))
    Move-Item -LiteralPath $repositoryPath -Destination $backupPath
    Write-Warning "$Reason The existing managed repository was preserved at: $backupPath"
    return $backupPath
}

function Prepare-HermesRepositoryForPin {
    param([string]$GitExecutable)

    $hermesRoot = Join-Path $env:LOCALAPPDATA "hermes"
    $repositoryPath = Join-Path $hermesRoot "hermes-agent"
    if (-not (Test-Path -LiteralPath $repositoryPath)) { return }

    if (-not (Test-Path -LiteralPath (Join-Path $repositoryPath ".git"))) {
        Move-HermesManagedRepositoryAside "The existing Hermes source directory is not a Git repository."
        return
    }

    $originResult = Invoke-NativeCommandCapture -FilePath $GitExecutable -ArgumentList @("-C", $repositoryPath, "remote", "get-url", "origin")
    if ($originResult.ExitCode -ne 0 -or $originResult.Text.Trim() -notmatch "^(?i:https://github\.com/|git@github\.com:|ssh://git@ssh\.github\.com:443/)NousResearch/hermes-agent(?:\.git)?$") {
        Move-HermesManagedRepositoryAside "The existing Hermes repository has an unexpected origin."
        return
    }

    $configResult = Invoke-NativeCommandCapture -FilePath $GitExecutable -ArgumentList @("-C", $repositoryPath, "config", "core.autocrlf", "false")
    if ($configResult.ExitCode -ne 0) {
        Move-HermesManagedRepositoryAside "The existing Hermes repository could not be configured for LF line endings."
        return
    }

    $statusResult = Invoke-NativeCommandCapture -FilePath $GitExecutable -ArgumentList @("-C", $repositoryPath, "status", "--porcelain", "--untracked-files=all")
    if ($statusResult.ExitCode -ne 0) {
        Move-HermesManagedRepositoryAside "The existing Hermes repository status could not be read."
        return
    }

    $statusLines = @($statusResult.Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($statusLines.Count -eq 0) { return }

    $dirtyPaths = @(
        foreach ($statusLine in $statusLines) {
            if ($statusLine.Length -ge 4) {
                $statusLine.Substring(3).Trim().Trim('"')
            }
        }
    )
    $onlyLockfileChurn = ($dirtyPaths.Count -gt 0 -and @($dirtyPaths | Where-Object { $_ -ne "uv.lock" }).Count -eq 0)

    if ($onlyLockfileChurn) {
        $lockfilePath = Join-Path $repositoryPath "uv.lock"
        if (Test-Path -LiteralPath $lockfilePath) {
            $backupRoot = Join-Path $hermesRoot "backups"
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
            $lockfileBackup = Join-Path $backupRoot ("uv.lock-before-easy-workshop-{0}.bak" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
            Copy-Item -LiteralPath $lockfilePath -Destination $lockfileBackup -Force
        }

        Write-Host "  - Repairing Git line-ending churn in the managed uv.lock file"
        $restoreResult = Invoke-NativeCommandCapture -FilePath $GitExecutable -ArgumentList @("-C", $repositoryPath, "-c", "core.autocrlf=false", "checkout", "--", "uv.lock")
        if ($restoreResult.ExitCode -eq 0) {
            $verifyResult = Invoke-NativeCommandCapture -FilePath $GitExecutable -ArgumentList @("-C", $repositoryPath, "status", "--porcelain", "--untracked-files=all")
            if ($verifyResult.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($verifyResult.Text)) {
                Write-Host "[OK] Managed Hermes repository is clean for the pinned checkout." -ForegroundColor Green
                return
            }
        }
    }

    Move-HermesManagedRepositoryAside "The managed Hermes repository contains changes that cannot be safely repaired automatically."
}

function Invoke-HermesRepositoryStage {
    param([string]$GitExecutable)

    # The upstream fresh-clone path replaces GIT_CONFIG_COUNT, losing our
    # autocrlf override, and checks out main before disabling CRLF conversion.
    # Initialize locally and fetch only the pin so no checkout can precede the
    # required configuration. Command-line -c also wins over inherited config.
    $repositoryPath = Join-Path $env:LOCALAPPDATA "hermes\hermes-agent"
    $gitOptions = @("-c", "core.autocrlf=false", "-c", "core.longpaths=true", "-c", "windows.appendAtomically=false")
    Prepare-HermesRepositoryForPin -GitExecutable $GitExecutable | Out-Host
    if (Test-Path -LiteralPath $repositoryPath) {
        $head = Invoke-NativeCommandCapture -FilePath $GitExecutable -ArgumentList ($gitOptions + @("-C", $repositoryPath, "rev-parse", "HEAD"))
        if ($head.ExitCode -eq 0 -and $head.Text.Trim() -eq $hermesCommit) {
            Write-Host "[OK] Existing Hermes checkout matches the workshop commit." -ForegroundColor Green
            return
        }
        Move-HermesManagedRepositoryAside "The existing checkout does not match the workshop commit." | Out-Host
    }

    Write-Host "  - Fetching pinned Hermes source over HTTPS"
    New-Item -ItemType Directory -Path $repositoryPath -Force | Out-Null
    $commands = @(
        @("init", "--quiet", $repositoryPath),
        @("-C", $repositoryPath, "config", "core.autocrlf", "false"),
        @("-C", $repositoryPath, "config", "core.longpaths", "true"),
        @("-C", $repositoryPath, "config", "windows.appendAtomically", "false"),
        @("-C", $repositoryPath, "remote", "add", "origin", "https://github.com/NousResearch/hermes-agent.git")
    )
    foreach ($command in $commands) {
        $result = Invoke-NativeCommandCapture -FilePath $GitExecutable -ArgumentList ($gitOptions + $command)
        if ($result.ExitCode -ne 0) {
            throw "Preparing pinned Hermes source failed (exit $($result.ExitCode)): $($command -join ' ')`n$($result.Text)"
        }
    }
    $transports = @(
        @{ Label = "HTTPS"; Url = "https://github.com/NousResearch/hermes-agent.git" },
        @{ Label = "SSH port 22"; Url = "git@github.com:NousResearch/hermes-agent.git" },
        @{ Label = "SSH port 443"; Url = "ssh://git@ssh.github.com:443/NousResearch/hermes-agent.git" }
    )
    $fetched = $false
    foreach ($transport in $transports) {
        Write-Host "  - Trying GitHub $($transport.Label)"
        $options = $gitOptions + @("-c", "http.connectTimeout=20", "-c", "http.lowSpeedLimit=1024", "-c", "http.lowSpeedTime=60")
        if ($transport.Label -like "SSH*") {
            $options += @("-c", "core.sshCommand=ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ConnectionAttempts=1")
        }
        $previousPrompt = $env:GIT_TERMINAL_PROMPT
        try {
            $env:GIT_TERMINAL_PROMPT = "0"
            $result = Invoke-NativeCommandCapture $GitExecutable ($options + @("-C", $repositoryPath, "fetch", "--depth", "1", "--no-tags", $transport.Url, $hermesCommit))
        }
        finally { $env:GIT_TERMINAL_PROMPT = $previousPrompt }
        if ($result.ExitCode -eq 0) {
            $origin = Invoke-NativeCommandCapture $GitExecutable ($gitOptions + @("-C", $repositoryPath, "remote", "set-url", "origin", $transport.Url))
            if ($origin.ExitCode -ne 0) { throw $origin.Text }
            $fetched = $true
            break
        }
        Write-Host "  - $($transport.Label) unavailable (Git exit $($result.ExitCode)); trying the next route."
        Write-Verbose $result.Text
    }
    if (-not $fetched) {
        throw "GitHub is unreachable through HTTPS and SSH. SSH requires an existing authorized GitHub key and trusted host entry. Ask IT to permit GitHub or use another approved network. Last Git error: $($result.Text)"
    }
    $checkout = Invoke-NativeCommandCapture $GitExecutable ($gitOptions + @("-C", $repositoryPath, "checkout", "--quiet", "--detach", $hermesCommit))
    if ($checkout.ExitCode -ne 0) { throw $checkout.Text }
    $head = Invoke-NativeCommandCapture -FilePath $GitExecutable -ArgumentList ($gitOptions + @("-C", $repositoryPath, "rev-parse", "HEAD"))
    $status = Invoke-NativeCommandCapture -FilePath $GitExecutable -ArgumentList ($gitOptions + @("-C", $repositoryPath, "status", "--porcelain", "--untracked-files=all"))
    if ($head.ExitCode -ne 0 -or $head.Text.Trim() -ne $hermesCommit -or $status.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($status.Text)) {
        throw "Hermes source verification failed: expected a clean checkout at $hermesCommit.`n$($head.Text)`n$($status.Text)"
    }
    Write-Host "[OK] Clean Hermes checkout verified at $hermesCommit." -ForegroundColor Green
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
        $actualPayloadSha = (Get-FileHash -LiteralPath $payloadFile -Algorithm SHA256).Hash.ToUpperInvariant()
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
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing -TimeoutSec 60
                break
            }
            catch {
                if ($attempt -eq 3) { throw "Cannot download the pinned installer from raw.githubusercontent.com. This step requires HTTPS even when Git uses SSH. Check this network's proxy/firewall. $($_.Exception.Message)" }
                Write-Host "  - Installer download interrupted; retrying ($attempt/3)."
                Start-Sleep -Seconds 3
            }
        }
        if ((Get-Item -LiteralPath $installerPath).Length -lt 10000) {
            throw "The downloaded Hermes installer is unexpectedly small."
        }

        Invoke-HermesInstaller "Hermes uv stage" @("-Stage", "uv", "-Commit", $hermesCommit)
        Invoke-HermesInstaller "Hermes Git stage" @("-Stage", "git", "-Commit", $hermesCommit)
        $hermesGitExecutable = Get-HermesGitExecutable
        Invoke-HermesRepositoryStage -GitExecutable $hermesGitExecutable
        Invoke-HermesInstaller "Hermes Python stage" @("-Stage", "python", "-Commit", $hermesCommit)
        # Source is already verified. Do not let the upstream installer fetch
        # it again using a different transport or reset its line-ending policy.
        foreach ($stage in @("node", "system-packages", "venv", "dependencies", "node-deps", "path", "config-templates", "platform-sdks", "bootstrap-marker")) {
            Invoke-HermesInstaller "Hermes $stage stage" @("-Stage", $stage, "-SkipSetup", "-Commit", $hermesCommit)
        }
    }
    else {
        Write-Host "Hermes installation was skipped by request. Existing installation will be validated."
    }

    $hermesBin = Join-Path $env:LOCALAPPDATA "hermes\bin"
    $pathEntries = @($env:Path -split ";")
    if ($pathEntries -notcontains $hermesBin) {
        $env:Path = "$hermesBin;$env:Path"
    }
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $userPathEntries = @($userPath -split ";")
    if ($userPathEntries -notcontains $hermesBin) {
        [Environment]::SetEnvironmentVariable("Path", (($hermesBin) + ";" + ($userPathEntries -join ";")).TrimEnd(";"), "User")
    }

    $hermesLauncher = Find-HermesLauncher
    $hermesVersion = (Invoke-Hermes $hermesLauncher @("--version") | Out-String).Trim()
    Write-Host $hermesVersion
    Write-Host "[OK] Hermes Agent is installed." -ForegroundColor Green

    Write-Step 3 "Download and verify Gemma 4"
    New-Item -ItemType Directory -Path $modelDirectory -Force | Out-Null
    $validModelExists = $false
    if (Test-Path -LiteralPath $modelPath) {
        $existingModelSha = (Get-FileHash -LiteralPath $modelPath -Algorithm SHA256).Hash.ToUpperInvariant()
        $validModelExists = ($existingModelSha -eq $expectedModelSha)
    }
    if ($ForceModelDownload) { $validModelExists = $false }

    if (-not $validModelExists) {
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

        $downloadedModelSha = (Get-FileHash -LiteralPath $modelPartialPath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($downloadedModelSha -ne $expectedModelSha) {
            throw "Gemma 4 checksum verification failed. The partial file was kept at $modelPartialPath."
        }
        Move-Item -LiteralPath $modelPartialPath -Destination $modelPath -Force
    }

    $verifiedModelSha = (Get-FileHash -LiteralPath $modelPath -Algorithm SHA256).Hash.ToUpperInvariant()
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
