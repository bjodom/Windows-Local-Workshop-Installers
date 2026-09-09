# Hermes Local Workshop — Prepared Environment

This package targets Gemma 4 26B-A4B IT (QAT Q4_0 GGUF), served as
`gemma-4-26b-a4b-local`. The easy installer prepares this directory. You do not need to compile
llama.cpp, install the Vulkan SDK, download the model manually, or configure
Hermes yourself.

## Start or confirm the local model server

After a Windows restart, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-HermesLocalWorkshop.ps1"
```

The script reuses the existing server if the correct model is already ready.

## Begin the skills lab

```powershell
cd ".\hermes-practice"
hermes
```

Follow `TASKS.md` in the parent directory. It contains the bundled-skill,
meme-generation, and custom-skill exercises.

## Stop the local server

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Stop-HermesLocalWorkshop.ps1"
```

The endpoint is local-only at `http://127.0.0.1:8080/v1`. Server and setup logs
are stored under `logs`.
