include("${CMAKE_CURRENT_LIST_DIR}/blender-cycles-headless-rtx.cmake")

# Offline scene mixdown for RenderBoost analysis workers. Keep desktop playback
# backends disabled; background mixdown only needs Audaspace and codec support.
set(WITH_AUDASPACE ON CACHE BOOL "" FORCE)
set(WITH_CODEC_SNDFILE ON CACHE BOOL "" FORCE)
set(WITH_RUBBERBAND ON CACHE BOOL "" FORCE)
