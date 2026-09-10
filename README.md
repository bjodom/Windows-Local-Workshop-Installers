# Windows Local Workshop Installers

Easy-setup Windows installers for running local, OpenAI-compatible LLM
inference endpoints on Intel hardware, paired with the Hermes Agent. Each
subfolder is an independent, self-contained workshop package with its own
installer, start/stop scripts, and documentation.

| Folder | Inference engine | Backend | Notes |
| --- | --- | --- | --- |
| [`llamacpp-workshop/`](llamacpp-workshop/readme.md) | llama.cpp | Vulkan (Intel GPU) | Ships a precompiled llama.cpp runtime; downloads and verifies the Gemma 4 model on first run. |
| [`ovms-workshop/`](ovms-workshop/README.md) | OpenVINO Model Server (OVMS) | OpenVINO | Downloads and verifies OVMS; supports multiple selectable models. |

Both packages:

- Install and configure the [Hermes Agent](https://github.com/NousResearch/hermes-agent) via its official non-interactive installer.
- Point Hermes at a local, `127.0.0.1`-only OpenAI-compatible endpoint.
- Verify downloads with SHA-256 before use.
- Are Windows-only and require no administrator account.

## Getting started

Each workshop is self-contained — extract or clone the repo, then follow the
`README` inside the relevant subfolder:

- **llama.cpp workshop:** see [llamacpp-workshop/readme.md](llamacpp-workshop/readme.md)
- **OVMS workshop:** see [ovms-workshop/README.md](ovms-workshop/README.md)

## Repository layout

```text
Windows-Local-Workshop-Installers/
├── llamacpp-workshop/   # Install-HermesLocalWorkshop.ps1 + precompiled llama.cpp payload
└── ovms-workshop/       # Install-OVMSLocalWorkshop.ps1 + OVMS download/setup scripts
```

## License

MIT — see [LICENSE](LICENSE). Third-party components are covered separately;
see each subfolder's own license/notices files (e.g.
[llamacpp-workshop/payload/THIRD_PARTY_NOTICES.md](llamacpp-workshop/payload/THIRD_PARTY_NOTICES.md)).
