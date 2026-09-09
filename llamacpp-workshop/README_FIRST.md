# Hermes Local Workshop — Easy Installation

This package prepares the complete local workshop environment automatically:

```text
Hermes Agent -> llama.cpp local API -> Gemma 4 26B-A4B Q4_0 -> Vulkan -> Intel GPU
```

Participants do **not** compile llama.cpp, install the Vulkan SDK, configure
Hermes manually, or enter the model-download commands themselves.

## Requirements

- Windows 10 or Windows 11, 64-bit
- An Intel GPU with a current Vulkan-capable Intel graphics driver
- Internet access to GitHub and Hugging Face
- At least 20 GB of free disk space remaining for the model download, plus space for Hermes and its dependencies
- No administrator account is required

The package contains the already-compiled Windows x64 Vulkan build of
llama.cpp. The setup downloads the pinned Gemma 4 model because including that
model would make the shared workshop ZIP approximately 14.4 GB larger.

## Model version and existing installations

This package uses **Gemma 4 26B-A4B IT, QAT Q4_0 GGUF**. The download is pinned
to a specific Hugging Face revision and verified with SHA-256. This larger model
passed model checksum, Intel Arc B390 Vulkan startup, and local chat checks
on one laptop on 2026-09-08. Workshop skills and the company hotspot still
require validation; this does not certify other laptop configurations.

If you previously installed the E4B package, close Hermes and stop the installed
server before rerunning setup (Windows locks the running runtime executable):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Hermes-Local-Workshop\hermes-llamacpp-gemma4-workshop-windows-x64-intel-vulkan-v0.3.0\Stop-HermesLocalWorkshop.ps1"
```

Setup downloads a separate 26B model file and updates the Hermes model alias.
The existing E4B model file is retained, so allow additional disk space.

## Run the setup

1. Extract the entire easy-installation ZIP.
2. Double-click `RUN_EASY_SETUP.cmd`.
3. Leave the window open while Gemma 4 downloads and the setup completes.

Alternatively, open PowerShell in the extracted folder and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Install-HermesLocalWorkshop.ps1"
```

The model download is approximately 14.4 GB and is automatically resumed if
the connection is interrupted. The script verifies the model checksum before
using it.

## When setup reports `WORKSHOP READY`

The local model server is already running in the background and Hermes is
configured. The PowerShell window is placed in the practice directory. Start
Hermes with:

```powershell
hermes
```

Open the exercise document from the parent directory:

```powershell
Invoke-Item "..\TASKS.md"
```

## After restarting Windows

The model server is not installed as a Windows service. Start it again with:

```powershell
cd "$env:USERPROFILE\Hermes-Local-Workshop\hermes-llamacpp-gemma4-workshop-windows-x64-intel-vulkan-v0.3.0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-HermesLocalWorkshop.ps1"
cd ".\hermes-practice"
hermes
```

To stop only the workshop model server:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Stop-HermesLocalWorkshop.ps1"
```

## What the setup changes

- Copies the precompiled llama.cpp runtime to
  `%USERPROFILE%\Hermes-Local-Workshop\hermes-llamacpp-gemma4-workshop-windows-x64-intel-vulkan-v0.3.0`
- Checks for `uv` (astral-sh) on `PATH` and installs it with `winget` if missing
- Installs Hermes Agent with the official non-interactive installer
  (`https://hermes-agent.nousresearch.com/install.ps1 -SkipSetup -NonInteractive`),
  the same one-liner as `iex (irm https://hermes-agent.nousresearch.com/install.ps1)`
- Lets that official installer provision its own Python, Node.js, Git, and
  required packages
- Asks for confirmation in an interactive console before starting the large
  (multi-GB) Gemma 4 download
- Downloads and verifies the Gemma 4 Q4_0 GGUF model
- Starts llama.cpp on `http://127.0.0.1:8080`
- Configures Hermes to use `http://127.0.0.1:8080/v1`
- Creates `hermes-practice` and copies the skills exercises as `TASKS.md`

The endpoint is bound to `127.0.0.1`, so it is not exposed to other computers.
Installation logs are saved under the installed workshop's `logs` directory.

## If setup stops

Read the red error message and the newest file in:

```text
%USERPROFILE%\Hermes-Local-Workshop\hermes-llamacpp-gemma4-workshop-windows-x64-intel-vulkan-v0.3.0\logs
```

The script is safe to run again. Completed downloads and installation stages
are reused when valid.

## Home and company networks

Double-click the same `RUN_EASY_SETUP.cmd` on either network. The Hermes installer
is fetched over HTTPS only (no SSH/Git clone), with automatic retries that honor
a server's `Retry-After` header if a download is rate-limited (HTTP 429).

Model downloads try curl, then Windows HTTPS (Windows proxy/certificate settings),
with bounded retries and resume support. If a server ignores resume requests,
the Windows downloader safely starts the file again. SHA-256 is checked afterward.

The network must still allow `hermes-agent.nousresearch.com`, Python package
hosting, Node.js, Hugging Face and its download CDN, and the `winget` package
source (only needed if `uv` is not already installed). Company proxy or firewall
restrictions may require IT assistance. Test the actual employee hotspot before
the workshop; home testing cannot certify that network.

