# YesterdayRender runtime artifacts

Public release assets for YesterdayRender worker runtime downloads.

This repo also builds a source-based Blender worker runtime intended for
YesterdayRender Cycles GPU pools:

- headless only
- NVIDIA CUDA + OptiX enabled
- no oneAPI/HIP backends
- no windowing/audio stack
- no USD/Hydra/MaterialX

Current default build: Blender 5.2.0.

Workflow:

- `.github/workflows/build-blender-cycles-runtime.yml`

Build profile:

- `blender-cycles-headless-rtx.cmake`
