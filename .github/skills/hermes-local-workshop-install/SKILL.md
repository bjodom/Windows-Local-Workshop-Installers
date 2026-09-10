---
name: hermes-local-workshop-install
description: "Use when: installing, repairing, validating, starting, or stopping the Hermes Local Workshop package on Windows x64 with an Intel Vulkan GPU, including llama.cpp, Gemma 4 GGUF download, Hermes configuration, and local API validation."
---

# Hermes Local Workshop Install

Use this skill to install, repair, validate, start, or stop the Hermes Local Workshop environment from this repository.

The PowerShell scripts in the repository are the source of truth. Do not reimplement their install logic manually.

## Installed Environment

The installer prepares:

- Hermes Agent
- precompiled llama.cpp Vulkan runtime
- Gemma 4 26B-A4B Q4_0 GGUF model
- local OpenAI-compatible endpoint at `http://127.0.0.1:8080/v1`
- Hermes model alias `gemma-4-26b-a4b-local`
- workshop practice directory and task files

## Preconditions

Before installation, confirm that the user has:

- Windows 10 or Windows 11, 64-bit
- an Intel GPU with a current Vulkan-capable Intel graphics driver
- internet access to GitHub, Hugging Face, the Hermes installer host, Python and Node package sources, and winget sources if `uv` is missing
- at least 20 GB free disk space for the model download and install artifacts
- the complete extracted workshop package, including the `payload` directory

Tell the user before installation that the Gemma 4 model download is approximately 14.4 GB.

For agent-driven or non-interactive setup, do not start the large model download unless the user has explicitly approved it. Pass `-AcceptLargeDownload` only after that approval.

## Standard Installation

From the repository root, run this for an interactive install:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Install-HermesLocalWorkshop.ps1"
```

For an agent-driven or non-interactive install after the user explicitly approves the large model download, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Install-HermesLocalWorkshop.ps1" -AcceptLargeDownload
```

If the user wants installation without starting the server, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Install-HermesLocalWorkshop.ps1" -AcceptLargeDownload -DoNotStartServer
```

If Hermes is already installed and should not be reinstalled, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Install-HermesLocalWorkshop.ps1" -AcceptLargeDownload -SkipHermesInstall
```

If the model must be redownloaded, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Install-HermesLocalWorkshop.ps1" -AcceptLargeDownload -ForceModelDownload
```

## Validation

After installation, verify the local API and Hermes configuration:

```powershell
curl.exe --silent --show-error --fail http://127.0.0.1:8080/health
hermes config get model.provider
hermes config get model.base_url
hermes config get model.default
```

Expected Hermes values are:

```text
custom
http://127.0.0.1:8080/v1
gemma-4-26b-a4b-local
```

Also verify that the ready marker exists:

```powershell
Test-Path "$env:USERPROFILE\Hermes-Local-Workshop\hermes-llamacpp-gemma4-workshop-windows-x64-intel-vulkan-v0.3.0\WORKSHOP_READY.txt"
```

## Start After Reboot

The model server is not installed as a Windows service. To start it after reboot, run:

```powershell
cd "$env:USERPROFILE\Hermes-Local-Workshop\hermes-llamacpp-gemma4-workshop-windows-x64-intel-vulkan-v0.3.0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-HermesLocalWorkshop.ps1"
cd ".\hermes-practice"
hermes
```

## Stop the Server

To stop only the workshop model server, run from the installed workshop directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Stop-HermesLocalWorkshop.ps1"
```

## Failure Handling

If setup fails, read the red error message and inspect the newest log under:

```text
%USERPROFILE%\Hermes-Local-Workshop\hermes-llamacpp-gemma4-workshop-windows-x64-intel-vulkan-v0.3.0\logs
```

The installer is safe to rerun. It reuses valid completed stages, resumes partial model downloads, and preserves invalid model files with timestamped names.
