set(WITH_HEADLESS ON CACHE BOOL "" FORCE)

# Worker runtime only: no desktop windowing/audio stack or viewer helpers.
set(WITH_BLENDER_THUMBNAILER OFF CACHE BOOL "" FORCE)
set(WITH_INTERNATIONAL OFF CACHE BOOL "" FORCE)
set(WITH_AUDASPACE OFF CACHE BOOL "" FORCE)
set(WITH_CODEC_FFMPEG ON CACHE BOOL "" FORCE)
set(WITH_CODEC_SNDFILE OFF CACHE BOOL "" FORCE)
set(WITH_COREAUDIO OFF CACHE BOOL "" FORCE)
set(WITH_JACK OFF CACHE BOOL "" FORCE)
set(WITH_OPENAL OFF CACHE BOOL "" FORCE)
set(WITH_PULSEAUDIO OFF CACHE BOOL "" FORCE)
set(WITH_PIPEWIRE OFF CACHE BOOL "" FORCE)
set(WITH_SDL_AUDIO OFF CACHE BOOL "" FORCE)
set(WITH_WASAPI OFF CACHE BOOL "" FORCE)
set(WITH_XR_OPENXR OFF CACHE BOOL "" FORCE)
set(WITH_INPUT_NDOF OFF CACHE BOOL "" FORCE)
set(WITH_X11_XINPUT OFF CACHE BOOL "" FORCE)
set(WITH_GHOST_SDL OFF CACHE BOOL "" FORCE)
set(WITH_GHOST_X11 OFF CACHE BOOL "" FORCE)
set(WITH_GHOST_WAYLAND OFF CACHE BOOL "" FORCE)
# Background renders with the GPU compositor or Grease Pencil still create a
# GHOST off-screen draw context. On Linux, the headless implementation uses
# EGL through the OpenGL backend; disabling every graphics backend makes that
# context null and crashes Blender before Cycles starts.
set(WITH_OPENGL_BACKEND ON CACHE BOOL "" FORCE)
set(WITH_VULKAN_BACKEND OFF CACHE BOOL "" FORCE)

# Keep core Cycles/image/runtime behavior; drop interchange and non-NVIDIA
# compute backends that do not help RenderBoost.io's Linux RTX pools.
set(WITH_OPENIMAGEDENOISE ON CACHE BOOL "" FORCE)
set(WITH_OPENIMAGEIO ON CACHE BOOL "" FORCE)
set(WITH_OPENCOLORIO ON CACHE BOOL "" FORCE)
set(WITH_OPENVDB ON CACHE BOOL "" FORCE)
set(WITH_USD OFF CACHE BOOL "" FORCE)
set(WITH_MATERIALX OFF CACHE BOOL "" FORCE)
set(WITH_HYDRA OFF CACHE BOOL "" FORCE)
set(WITH_DRACO OFF CACHE BOOL "" FORCE)
set(WITH_CYCLES_OSL ON CACHE BOOL "" FORCE)
# Blender's Linux dependency bundle builds Embree with SYCL enabled. Even with
# Cycles oneAPI disabled, that makes the Blender executable and libembree depend
# on the Intel SYCL/Unified Runtime stack. This runtime targets NVIDIA workers;
# use Cycles' native CPU BVH for CPU fallback so the Intel-only chain can be
# removed without affecting CUDA or OptiX.
set(WITH_CYCLES_EMBREE OFF CACHE BOOL "" FORCE)
set(WITH_CYCLES_DEVICE_CUDA ON CACHE BOOL "" FORCE)
set(WITH_CYCLES_DEVICE_OPTIX ON CACHE BOOL "" FORCE)
set(WITH_CUDA_DYNLOAD ON CACHE BOOL "" FORCE)
set(WITH_CYCLES_DEVICE_HIP OFF CACHE BOOL "" FORCE)
set(WITH_CYCLES_HIP_BINARIES OFF CACHE BOOL "" FORCE)
set(WITH_CYCLES_DEVICE_HIPRT OFF CACHE BOOL "" FORCE)
set(WITH_CYCLES_DEVICE_ONEAPI OFF CACHE BOOL "" FORCE)
set(WITH_CYCLES_ONEAPI_BINARIES OFF CACHE BOOL "" FORCE)

# Portable runtime for worker download/install.
set(WITH_INSTALL_PORTABLE ON CACHE BOOL "" FORCE)
set(WITH_CPU_CHECK OFF CACHE BOOL "" FORCE)
set(WITH_PYTHON_INSTALL_REQUESTS OFF CACHE BOOL "" FORCE)
set(WITH_PYTHON_INSTALL_ZSTANDARD OFF CACHE BOOL "" FORCE)
