#!/usr/bin/env bash
set -Eeuo pipefail

RUNTIME_GET_URL="${RUNTIME_GET_URL:?RUNTIME_GET_URL is required}"
SPLASHY_GET_URL="${SPLASHY_GET_URL:?SPLASHY_GET_URL is required}"
STATUS_PUT_URL="${STATUS_PUT_URL:?STATUS_PUT_URL is required}"
LOG_PUT_URL="${LOG_PUT_URL:?LOG_PUT_URL is required}"
RESULT_PUT_URL="${RESULT_PUT_URL:?RESULT_PUT_URL is required}"
IMAGE_PUT_URL="${IMAGE_PUT_URL:?IMAGE_PUT_URL is required}"
WORK_ROOT="${WORK_ROOT:-/work/renderboost-splashy-validation}"
SPLASHY_FRAME="${SPLASHY_FRAME:-610}"

mkdir -p "$WORK_ROOT"
LOG_PATH="$WORK_ROOT/splashy-validation.log"
STATUS_PATH="$WORK_ROOT/status.json"
RESULT_PATH="$WORK_ROOT/result.json"
IMAGE_PATH="$WORK_ROOT/splashy-frame-${SPLASHY_FRAME}.png"
exec > >(tee -a "$LOG_PATH") 2>&1

upload_file() {
  local path="$1"
  local url="$2"
  [[ -s "$path" ]] || return 0
  curl -fsS --retry 8 --retry-all-errors --retry-delay 3 \
    -X PUT --upload-file "$path" "$url"
}

write_status() {
  local phase="$1"
  local detail="$2"
  python3 - "$STATUS_PATH" "$phase" "$detail" <<'PY'
import datetime
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(
    json.dumps(
        {
            "phase": sys.argv[2],
            "detail": sys.argv[3],
            "updated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        },
        sort_keys=True,
    )
    + "\n",
    encoding="utf-8",
)
PY
  upload_file "$STATUS_PATH" "$STATUS_PUT_URL" || true
}

finish() {
  local exit_code=$?
  if (( exit_code == 0 )); then
    write_status "complete" "Splashy frame ${SPLASHY_FRAME} rendered on OptiX."
  else
    write_status "failed" "Splashy validation exited with status ${exit_code}."
  fi
  upload_file "$LOG_PATH" "$LOG_PUT_URL" || true
  exit "$exit_code"
}
trap finish EXIT

install_optix_driver_libraries_if_needed() {
  if ldconfig -p 2>/dev/null | grep -q 'libnvoptix.so.1'; then
    return 0
  fi

  local driver_version compatibility_version runfile_url temporary_root runfile extract_root library
  driver_version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n 1 | tr -d '[:space:]')"
  case "$driver_version" in
    610.*) compatibility_version="610.43.03" ;;
    596.*|595.*) compatibility_version="595.71.05" ;;
    591.*|590.*) compatibility_version="590.48.01" ;;
    581.*|580.*) compatibility_version="580.159.03" ;;
    576.*|575.*) compatibility_version="575.64.05" ;;
    573.*|572.*|571.*|570.*) compatibility_version="570.211.01" ;;
    *) compatibility_version="$driver_version" ;;
  esac
  runfile_url="https://download.nvidia.com/XFree86/Linux-x86_64/${compatibility_version}/NVIDIA-Linux-x86_64-${compatibility_version}-no-compat32.run"
  temporary_root="$(mktemp -d)"
  runfile="$temporary_root/nvidia-driver.run"
  extract_root="$temporary_root/extract"

  curl -fsSL --retry 8 --retry-all-errors --retry-delay 3 "$runfile_url" -o "$runfile"
  sh "$runfile" -x --target "$extract_root"
  mkdir -p /usr/local/nvidia/lib64
  while IFS= read -r library; do
    cp -a "$library" /usr/local/nvidia/lib64/
  done < <(find "$extract_root" -type f \( \
    -name 'libnvoptix.so*' \
    -o -name 'libnvidia-rtcore.so*' \
    -o -name 'libnvidia-ptxjitcompiler.so*' \
    -o -name 'libnvidia-nvvm.so*' \
    -o -name 'libnvidia-gpucomp.so*' \
    -o -name 'libnvidia-compiler.so*' \
    -o -name 'libnvidia-fatbinaryloader.so*' \
  \))
  find /usr/local/nvidia/lib64 -maxdepth 1 -type f -name 'libnvoptix.so.*' \
    -printf '%f\n' | sort -V | tail -n 1 | xargs -r -I{} ln -sf {} /usr/local/nvidia/lib64/libnvoptix.so.1
  printf '%s\n' /usr/local/nvidia/lib64 >/etc/ld.so.conf.d/renderboost-nvidia.conf
  ldconfig
  rm -rf "$temporary_root"
  ldconfig -p | grep -q 'libnvoptix.so.1'
}

write_status "provisioning" "Installing validation dependencies and OptiX user-mode libraries."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl xz-utils zstd
nvidia-smi
install_optix_driver_libraries_if_needed

runtime_archive="$WORK_ROOT/blender-sm86.tar.xz"
project_archive="$WORK_ROOT/splashy-frame-610-input.tar.zst"
runtime_root="$WORK_ROOT/runtime"
project_root="$WORK_ROOT/project"
mkdir -p "$runtime_root" "$project_root"

write_status "download" "Downloading the sm86 Blender runtime and private Splashy fixture."
curl -fsSL --retry 8 --retry-all-errors --retry-delay 3 \
  "$RUNTIME_GET_URL" -o "$runtime_archive"
curl -fsSL --retry 8 --retry-all-errors --retry-delay 3 \
  "$SPLASHY_GET_URL" -o "$project_archive"
tar -xJf "$runtime_archive" -C "$runtime_root"
tar --zstd -xf "$project_archive" -C "$project_root"

blender_binary="$(find "$runtime_root" -mindepth 2 -maxdepth 2 -type f -name blender -perm -111 | head -n 1)"
project_file="$project_root/splashy-packed.blend"
test -x "$blender_binary"
test -s "$project_file"
test -d "$project_root/blendcache_splashy-packed"

cat >"$WORK_ROOT/render_splashy.py" <<'PY'
import bpy
import json
import os
import time

frame = int(os.environ["SPLASHY_FRAME"])
output = os.environ["SPLASHY_OUTPUT"]
result_path = os.environ["SPLASHY_RESULT"]

scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.device = "GPU"
scene.frame_set(frame)
scene.render.image_settings.file_format = "PNG"
scene.render.filepath = output
scene.render.use_file_extension = True

preferences = bpy.context.preferences.addons["cycles"].preferences
preferences.compute_device_type = "OPTIX"
refresh = getattr(preferences, "refresh_devices", None)
if callable(refresh):
    refresh()
else:
    preferences.get_devices()

devices = []
selected = []
for device in preferences.devices:
    record = {"name": str(device.name), "type": str(device.type)}
    device.use = str(device.type).upper() == "OPTIX"
    record["enabled"] = bool(device.use)
    devices.append(record)
    if device.use:
        selected.append(str(device.name))
if not selected:
    raise RuntimeError(f"OPTIX enumerated zero GPU devices: {devices}")

payload = {
    "backend": "OPTIX",
    "devices": devices,
    "frame": frame,
    "project": bpy.data.filepath,
    "resolution": [
        scene.render.resolution_x,
        scene.render.resolution_y,
        scene.render.resolution_percentage,
    ],
    "samples": scene.cycles.samples,
    "shadingSystem": str(scene.cycles.shading_system),
}
print("__SPLASHY_CONFIG__ " + json.dumps(payload, sort_keys=True), flush=True)

started = time.monotonic()
bpy.ops.render.render(write_still=True)
payload["renderSeconds"] = time.monotonic() - started
payload["output"] = output
with open(result_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
print("__SPLASHY_RESULT__ " + json.dumps(payload, sort_keys=True), flush=True)
PY

write_status "render" "Rendering Splashy frame ${SPLASHY_FRAME} at its saved full settings on OptiX."
export SPLASHY_FRAME
export SPLASHY_OUTPUT="$IMAGE_PATH"
export SPLASHY_RESULT="$RESULT_PATH"
"$blender_binary" --background "$project_file" --python "$WORK_ROOT/render_splashy.py"
test -s "$IMAGE_PATH"
test -s "$RESULT_PATH"

write_status "upload" "Uploading the Splashy frame and validation metadata."
upload_file "$IMAGE_PATH" "$IMAGE_PUT_URL"
upload_file "$RESULT_PATH" "$RESULT_PUT_URL"
