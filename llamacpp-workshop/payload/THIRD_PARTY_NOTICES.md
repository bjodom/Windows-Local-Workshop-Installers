# Third-Party Notices and Provenance

## llama.cpp

- Project: https://github.com/ggml-org/llama.cpp
- Release: `v0.3.0`
- Commit: `c1d0e7a004015f23bc0233470b747b596f29b264`
- License: MIT; a copy is included at `licenses/llama.cpp-LICENSE`

The package was compiled for Windows x64 with Vulkan enabled, shared libraries
disabled, the MSVC runtime linked statically, OpenMP disabled, native CPU tuning
disabled, the server UI disabled, and HTTPS disabled. It is intended for a local
HTTP endpoint only.

## Vulkan

The Vulkan loader and graphics driver are not bundled. `vulkan-1.dll` must be
provided by the attendee system's GPU driver. LunarG Vulkan SDK `1.4.357.0` was
used only on the maintainer build machine to compile the Vulkan shaders.

## Gemma 4 model

The model is not bundled with this runtime ZIP.

- Repository: https://huggingface.co/google/gemma-4-26B-A4B-it-qat-q4_0-gguf
- File: `gemma-4-26B_q4_0-it.gguf`
- SHA-256: `3eca3b8f6d7baf218a7dd6bba5fb59a56ee25fe2d567b6f5f589b4f697eca51d`
- License displayed by the repository: Apache-2.0

Confirm organizational model-use and redistribution policy before mirroring the
model into an internal artifact repository.

