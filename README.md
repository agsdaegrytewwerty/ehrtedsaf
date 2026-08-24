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
- no windowing or desktop audio playback stack
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

An opt-in `audio` workflow profile uses
`blender-cycles-headless-rtx-audio.cmake`. It retains the standard runtime's
rendering features while enabling Audaspace, libsndfile, Rubber Band, and the
already-present FFmpeg codec support for background scene mixdown. OpenAL,
JACK, PulseAudio, PipeWire, and SDL playback remain disabled.

Audio releases use distinct `-audio` asset names and require a release tag
containing `audio`. Release publication only occurs for manual workflow
dispatches, so branch pushes cannot replace an existing release.
