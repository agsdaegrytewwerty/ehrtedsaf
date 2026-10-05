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
resulting digest, rather than a mutable tag. The current package permits
anonymous pulls. If the package is made private, Salad also accepts authenticated
GHCR pulls. Runtime loading into RAM/VRAM still occurs after Salad starts
billing. A GPU canary is required before switching the image pool.

## ProjectSwift H3 video workers

`Dockerfile.h3` installs the native H3 ComfyUI revision and CUDA 13 dependencies,
using the checksum-verified SM86-only PyTorch build from the image runtime release.
It targets the RTX 3090 worker pool. The full native H3 nodes remain installed.
Its `worker` target contains the pinned beta5 TURBO W4A8 diffusion model and
video/audio VAEs from `h3/h3_runtime.json`. Its `conditioning` target contains
Qwen3-VL and the video VAE for an isolated end-to-end canary; it is not a
generation worker. Production conditioning remains in the Swift app's local
workflow.

Weights are size/SHA-256 verified while streaming at build time. Models larger
than 7 GB are split into 7 GB parts, copied in separate final image layers, and
assembled and verified in writable storage at boot. The assembled file is never
committed into a large registry layer. Use at least 100 GiB container storage to
allow for the image, assembled model and outputs. Native H3 node imports and
routes are checked with networking disabled before publication.

The workflow publishes immutable `h3-worker-<commit>` and
`h3-conditioning-<commit>` tags in the existing public `projectswift-comfyui`
GHCR package. Image workflow tags and digests are preserved. GPU validation is
required before production rollout.

No ComfyUI workflow graph is embedded in either image. The Swift app submits
graphs per job. ComfyUI's user/settings directories are writable. Process launch
settings can be replaced with `PROJECTSWIFT_COMFY_ARGS_JSON`, for example:

```json
["--normalvram", "--reserve-vram", "0.5", "--disable-auto-launch"]
```

Alternatively, set `PROJECTSWIFT_COMFY_ARGS_FILE` to a writable JSON file with
the same array. File settings take precedence. Process changes require a worker
restart, but no image rebuild; workflow changes apply with the next prompt.
Keep persistent settings in the provider environment or external storage, since
a reallocated worker loses its writable container layer. No registry, Salad,
or output-buffer credentials are included in the image.
