# Hermes Skills Hands-on Lab

## Built-in, installed, and custom skills with local Gemma 4

**Time:** 50 minutes you Kathy
**Format:** Work in pairs; each person runs the commands on their own computer
**Goal:** Use three types of Hermes skill and produce evidence that each one worked

By the end of this lab, you will be able to:

1. find and invoke a skill bundled with Hermes;
2. inspect, install, verify, and use an official optional skill; and
3. create a focused `SKILL.md`, load it in a new session, and use it.

## What you will produce

Keep all generated files. They are your evidence that each skill worked.

| Exercise | Skill type                      | Deliverable                                        |
| -------- | ------------------------------- | -------------------------------------------------- |
| 1        | Bundled                         | `DEBUG_REPORT.md`                                |
| 2        | Installed from the official Hub | `LOCAL_AI_MEME.png` and `MY_WORKSHOP_MEME.png` |
| 3        | Custom                          | `LOCAL_AI_READINESS.md` and your `SKILL.md`    |

## Before you begin

Complete the main `README.md` first. The following must already work:

- `llama-server` is running in a separate PowerShell window;
- `http://127.0.0.1:8080/health` responds successfully;
- Hermes is configured with provider `custom`, base URL
  `http://127.0.0.1:8080/v1`, and model `gemma-4-26b-a4b-local`; and
- a normal Hermes prompt receives an answer from the local model.

Open a new PowerShell window, move to the extracted workshop directory, and
then enter the practice directory created during the main lab:

```powershell
cd "$env:USERPROFILE\Hermes-Local-Workshop\hermes-llamacpp-gemma4-workshop-windows-x64-intel-vulkan-v0.3.0"
cd ".\hermes-practice"
```

If you extracted the ZIP somewhere else, use that location instead. Confirm
that the server and Hermes are ready:

```powershell
curl.exe --silent --show-error --fail http://127.0.0.1:8080/health
hermes config get model.provider
hermes config get model.base_url
hermes config get model.default
```

Expected configuration values are `custom`,
`http://127.0.0.1:8080/v1`, and `gemma-4-26b-a4b-local`.

> Important: skills added on disk become available in a **new Hermes session**.
> This lab exits and restarts Hermes after every skill change for that reason.

---

## Exercise 1 - Use a bundled skill

**Time:** 12 minutes
**Skill:** `systematic-debugging`
**Scenario:** A health check is failing because it was given the wrong endpoint.

### 1. Prove that the skill is already installed

Run this from PowerShell, not from inside a Hermes chat:

```powershell
hermes skills list | Select-String "systematic-debugging"
```

You should see the skill name and a description about root-cause debugging. You
did not download this skill; it was bundled with Hermes.

### 2. Establish the evidence yourself

Run both commands and compare their exit behavior:

```powershell
curl.exe --silent --show-error --fail http://127.0.0.1:8080/health
curl.exe --silent --show-error --fail http://127.0.0.1:8081/health
```

Port `8080` should succeed. Port `8081` should fail. Do not start a second
server and do not change the working server.

### 3. Give the bundled skill a real task

Start Hermes:

```powershell
hermes
```

At the Hermes prompt, enter this as one message:

```text
/systematic-debugging Investigate this local API failure systematically. The failing command is: curl.exe --silent --show-error --fail http://127.0.0.1:8081/health. The llama.cpp server is expected to be local. Reproduce the failure, gather evidence, identify the root cause before proposing a correction, and prove the correction with a successful command. Create DEBUG_REPORT.md in the current directory with these headings: Symptom, Evidence, Root Cause, Correction, Verification. Do not change the server configuration.
```

Approve only the creation of `DEBUG_REPORT.md` if Hermes asks for permission.
When Hermes finishes, exit it with `Ctrl+C`, return to PowerShell, and inspect
the result:

```powershell
Get-Content ".\DEBUG_REPORT.md"
```

### Success check

Your report passes if it:

- records the failing `8081` command;
- identifies a port mismatch as the root cause;
- separates evidence from the proposed correction.

---

## Exercise 2 - Install and use the Meme Generation skill

**Time:** 15-20 minutes
**Skill:** `meme-generation`
**Scenario:** Create real PNG memes with the local Gemma model.

This official optional skill downloads a classic Imgflip template and adds
captions with Python Pillow. No API key or paid service is required. The first
use requires internet access to download the selected template. The pinned
Hermes build already includes Pillow, so do not run a separate `pip install`.

### 1. Check internet access to the template

Run this from PowerShell:

```powershell
$response = Invoke-WebRequest `
    -Uri "https://i.imgflip.com/30b1gx.jpg" `
    -Method Head `
    -UseBasicParsing

$response.StatusCode
```

The expected result is `200`. If it fails, the company network may be blocking
Imgflip; resolve that before the workshop.

### 2. Inspect the skill before installing it

```powershell
hermes skills inspect official/creative/meme-generation
```

Confirm that the output shows:

- name `meme-generation`;
- source and trust `official`;
- Windows platform support;
- PNG output; and
- external access to download an Imgflip template.

Inspection before installation is the habit to use for every downloaded skill.

### 3. Install, audit, and verify

```powershell
hermes skills install official/creative/meme-generation
hermes skills list | Select-String "meme-generation"
hermes skills audit
```

Do not use `--force` if Hermes reports a security problem. Read the audit result
instead.

### 4. Start a fresh Hermes session

Installed skills are loaded into new sessions. Confirm that PowerShell is in
the `hermes-practice` directory and start Hermes:

```powershell
hermes
```

### 5. Create the first controlled meme

At the Hermes prompt, enter this as one message:

```text
/meme-generation Use the classic Drake template to create a workshop meme.
Reject caption: SENDING EVERY PROMPT TO THE CLOUD
Approve caption: RUNNING GEMMA 4 LOCALLY ON MY INTEL GPU
Keep the captions exactly as written. Use the classic template mode, not custom AI image generation. Save the finished PNG as ./LOCAL_AI_MEME.png in the current directory. After creating it, tell me the exact output path.
```

Hermes should load the skill, download the Drake template, add both captions,
and save `LOCAL_AI_MEME.png`. Exit Hermes with `Ctrl+C` after it finishes.

### 6. Verify the output from PowerShell

```powershell
Test-Path ".\LOCAL_AI_MEME.png"
Get-Item ".\LOCAL_AI_MEME.png" |
    Select-Object Name, Length, LastWriteTime
Invoke-Item ".\LOCAL_AI_MEME.png"
```

`Test-Path` must return `True`. Confirm that the Drake template is visible,
both captions are readable and in the correct panels, and the image is not
empty or corrupted.

### 7. Creative team challenge

Start a new Hermes session:

```powershell
hermes
```

At the Hermes prompt, enter:

```text
/meme-generation Create a second classic-template meme about the funniest or most frustrating command-line mistake someone could make during this local-AI workshop. Select the most appropriate curated template yourself. Keep every caption under eight words. Make it friendly and appropriate for work. Save it as ./MY_WORKSHOP_MEME.png.
```

Exit Hermes and open the result:

```powershell
Test-Path ".\MY_WORKSHOP_MEME.png"
Invoke-Item ".\MY_WORKSHOP_MEME.png"
```

### Success check

The exercise passes if:

- `meme-generation` appears in `hermes skills list`;
- the skill is invoked through `/meme-generation`;
- `LOCAL_AI_MEME.png` exists, opens, and contains the required captions;
- `MY_WORKSHOP_MEME.png` contains an original, workplace-appropriate joke; and
- both images were produced through the local Gemma model and installed skill.

---

## Exercise 3 - Create and use a custom skill

**Time:** 20 minutes
**Skill:** `local-ai-readiness`
**Scenario:** Turn the workshop's repeated readiness checks into a reusable,
read-only procedure.

### 1. Find the active Hermes home and create the skill directory

Run this from PowerShell:

```powershell
$hermesHome = [Environment]::GetEnvironmentVariable("HERMES_HOME", "User")
if ([string]::IsNullOrWhiteSpace($hermesHome)) {
    $hermesHome = Join-Path $env:LOCALAPPDATA "hermes"
}
$skillDirectory = Join-Path $hermesHome "skills\workshop\local-ai-readiness"
$skillFile = Join-Path $skillDirectory "SKILL.md"
New-Item -ItemType Directory -Path $skillDirectory -Force | Out-Null
$skillFile
```

The last command should print a path ending in
`skills\workshop\local-ai-readiness\SKILL.md`.

### 2. Author `SKILL.md` from the command line

Copy this whole block into PowerShell. It writes UTF-8 without a byte-order
mark, which avoids frontmatter parsing problems on Windows:

```powershell
$skillContent = @'
---
name: local-ai-readiness
description: Validate local Hermes and llama.cpp readiness.
version: 1.0.0
platforms: [windows]
metadata:
  hermes:
    tags: [local-ai, llama-cpp, validation]
    category: workshop
    requires_toolsets: [terminal]
---

# Local AI Readiness

## When to Use

Use this skill when the user asks whether the Windows Hermes workshop runtime,
local llama.cpp endpoint, and configured model are ready for a hands-on task.

## Procedure

1. Work read-only. Do not change configuration, start or stop processes,
   download files, expose the endpoint, or delete anything.
2. Use the terminal to call `http://127.0.0.1:8080/health`. Record the actual
   response or failure.
3. Call `http://127.0.0.1:8080/v1/models`. Record the advertised model ID.
4. Read `model.provider`, `model.base_url`, and `model.default` with
   `hermes config get` commands.
5. Compare the evidence. The provider must be `custom`; the base URL must be
   `http://127.0.0.1:8080/v1`; the configured default must be advertised by the
   models endpoint; and the health check must pass.
6. Create `LOCAL_AI_READINESS.md` in the current directory. Include an Evidence
   table with Check, Expected, Actual, and Result columns, followed by a Final
   Verdict and Recommended Next Action.
7. Report `READY` only when every required check passes. Otherwise report
   `NOT READY` and name the failed check without attempting to fix it.

## Pitfalls

- Do not treat an HTTP response as proof that Hermes points to the same model.
- Do not claim a check passed unless command output supports it.
- Do not confuse the browser page at port 8080 with the `/v1` API base URL.
- Never include secrets or unrelated environment variables in the report.

## Verification

Read `LOCAL_AI_READINESS.md` after writing it and confirm that every result has
captured evidence and that the final verdict agrees with the table.
'@
$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($skillFile, $skillContent, $utf8WithoutBom)
Get-Content -LiteralPath $skillFile
```

### 3. Confirm that Hermes discovers it

```powershell
hermes skills list | Select-String "local-ai-readiness"
```

If nothing is returned, see Troubleshooting below before continuing.

### 4. Use your custom skill in a new session

```powershell
hermes
```

At the Hermes prompt, enter:

```text
/local-ai-readiness Validate this computer and create LOCAL_AI_READINESS.md in the current directory. Show me the final verdict and the evidence you captured.
```

Approve only read-only terminal checks and creation of the requested report.
Exit Hermes with `Ctrl+C`, then inspect the result:

```powershell
Get-Content ".\LOCAL_AI_READINESS.md"
```

### Success check

Your work passes if:

- `hermes skills list` discovers `local-ai-readiness`;
- the slash command loads without an unknown-skill error;
- the report contains actual endpoint and Hermes configuration evidence;
- its model IDs agree; and
- the verdict follows the rules in your `SKILL.md`.

---

## Optional cleanup after the workshop

Keep the skills if you want to reuse them. To remove only the two skills added
in this lab, first uninstall the Hub skill:

```powershell
hermes skills uninstall meme-generation
```

Then preview the exact custom directory before deleting it:

```powershell
Get-ChildItem -LiteralPath $skillDirectory -Force
```

If it contains only the `local-ai-readiness` skill you created in this exercise:

```powershell
Remove-Item -LiteralPath $skillDirectory -Recurse -Force
```

Do not delete the whole `skills` directory; it also contains Hermes's bundled
skills.

## Troubleshooting

### A newly installed skill is not recognized

Exit Hermes completely with `Ctrl+C`, verify the skill from PowerShell, and
start `hermes` again. Skills added on disk are loaded in new sessions.

### The custom skill is not listed

Confirm the filename, frontmatter, and active home:

```powershell
$skillFile
Test-Path -LiteralPath $skillFile
Get-Content -LiteralPath $skillFile -TotalCount 15
[Environment]::GetEnvironmentVariable("HERMES_HOME", "User")
```

The file must be named exactly `SKILL.md`, and its first line must be `---`.

### The report says `NOT READY`

That is a valid skill result, not a skill failure. Use the Evidence table to
identify whether the server, model listing, or Hermes configuration failed.
Return to the relevant part of `README.md`, correct it manually, and rerun the
skill in a fresh session.

## References

- Hermes Working with Skills:
  https://hermes-agent.nousresearch.com/docs/guides/work-with-skills
- Hermes Skills System:
  https://hermes-agent.nousresearch.com/docs/user-guide/features/skills
- Hermes Optional Skills Catalog:
  https://hermes-agent.nousresearch.com/docs/reference/optional-skills-catalog
