# YesterdayRender runtime artifacts

Public release assets for YesterdayRender worker runtime downloads.

This repo also builds a source-based Blender worker runtime intended for
YesterdayRender Cycles GPU pools:

- headless only
- NVIDIA OptiX + CUDA enabled
- Open Shading Language enabled for OptiX OSL projects
- FFmpeg enabled for video-backed image textures
- headless EGL/OpenGL context support for GPU-composited scenes
- no oneAPI/HIP backends
- no windowing/audio stack
- no USD/Hydra/MaterialX

Current default build: Blender 5.2.0.

Releases include a safe archive plus SM75, SM86, SM89, and SM120 family
archives. The family archives retain the shared OptiX/OSL payloads, one
compatible CUDA cubin family, and the lowest official CUDA PTX fallback.
Blender 5.2 does not ship an SM89 cubin, so the SM89 archive carries NVIDIA's
forward-compatible SM86 cubin.

Workflow:

- `.github/workflows/build-blender-cycles-runtime.yml`

Build profile:

- `blender-cycles-headless-rtx.cmake`

## ProjectSwift image workflows

`Dockerfile.comfyui` builds a separate Linux amd64 image for Standard, Scratch,
4to5, and matte workflows on SM86 GPUs. It contains the checksum-verified
ProjectSwift `v1.0.1` CUDA 13 runtime and `ilustmix_v9.safetensors`. It contains
no video model assets. The startup command performs local checks and launches
ComfyUI; there is no runtime model download or package installation.

`.github/workflows/build-comfyui-image.yml` validates the installed runtime
with networking disabled before pushing
`ghcr.io/agsdaegrytewwerty/projectswift-comfyui:image-<commit>`. Deploy the
resulting digest, rather than a mutable tag. Keep the model image private
unless redistribution of its contents is intended; Salad accepts authenticated
GHCR pulls. Runtime loading into RAM/VRAM still occurs after Salad starts
billing. A GPU canary is required before switching the image pool.
