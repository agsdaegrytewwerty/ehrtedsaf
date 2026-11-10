# Settings Blender 5.3 needs on top of the 5.2 profiles; the runtime workflow adds this file for 5.3 and later.
#
# 5.3 replaced WITH_CYCLES_EMBREE with WITH_EMBREE and also uses Embree in Blender's own geometry BVH (Raycast,
# Sample Nearest, Proximity, Surface Deform and others). Without it those fall back to a path official 5.3 builds
# never run, so unlike 5.2 it stays on, with the SYCL/Unified Runtime libraries Embree links.
set(WITH_EMBREE ON CACHE BOOL "" FORCE)

# New interchange library in 5.3; not needed to render an authored .blend.
set(WITH_OPENTIMELINEIO OFF CACHE BOOL "" FORCE)
