#!/usr/bin/env bash
set -Eeuo pipefail

BLENDER_VERSION="${BLENDER_VERSION:-5.2.0}"
BLENDER_SERIES="${BLENDER_SERIES:-5.2}"
RELEASE_LABEL="${RELEASE_LABEL:-blender-5.2.0-cycles-headless-rtx-osl-v1}"
ASSET_PREFIX="${ASSET_PREFIX:-blender-${BLENDER_VERSION}-linux-x64-cycles-headless-rtx-osl}"
OPTIX_HEADERS_COMMIT="${OPTIX_HEADERS_COMMIT:-df7390b16bce5244b7352ca6d3e320f838297072}"
WORK_ROOT="${WORK_ROOT:-/work/renderboost-blender-build}"
RESULT_PUT_URL="${RESULT_PUT_URL:?RESULT_PUT_URL is required}"
STATUS_PUT_URL="${STATUS_PUT_URL:?STATUS_PUT_URL is required}"
LOG_PUT_URL="${LOG_PUT_URL:?LOG_PUT_URL is required}"

mkdir -p "$WORK_ROOT"
LOG_PATH="$WORK_ROOT/build.log"
STATUS_PATH="$WORK_ROOT/status.json"
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
    write_status "complete" "Build, GPU validation, and result upload completed."
  else
    write_status "failed" "Builder exited with status ${exit_code}."
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

  echo "Installing OptiX user-mode libraries ${compatibility_version} for host driver ${driver_version}"
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

write_status "provisioning" "Installing build dependencies."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  build-essential \
  ca-certificates \
  clang-18 \
  cmake \
  curl \
  git \
  git-lfs \
  lld-18 \
  ninja-build \
  pkg-config \
  python3 \
  ripgrep \
  xz-utils \
  zstd

nvidia-smi
install_optix_driver_libraries_if_needed

cd "$WORK_ROOT"
rm -rf blender-src release-config optix-sdk build dist official-runtime smoke

write_status "source" "Cloning Blender ${BLENDER_VERSION} and the lightweight release profile."
export GIT_LFS_SKIP_SMUDGE=1
git clone --depth 1 --branch "v${BLENDER_VERSION}" \
  https://projects.blender.org/blender/blender.git blender-src
git clone --depth 1 https://github.com/agsdaegrytewwerty/ehrtedsaf.git release-config
sed -i \
  's/set(WITH_CYCLES_OSL OFF /set(WITH_CYCLES_OSL ON /' \
  release-config/blender-cycles-headless-rtx.cmake
grep -q 'WITH_CYCLES_OSL ON' release-config/blender-cycles-headless-rtx.cmake

(
  cd blender-src
  git lfs install --local
  git lfs pull --include="release/datafiles/startup.blend" --exclude=""
  python3 build_files/utils/make_update.py --no-blender
)

optix_headers_archive="$WORK_ROOT/optix-headers.tar.gz"
curl -fsSL --retry 8 --retry-all-errors --retry-delay 3 \
  "https://github.com/NVIDIA/OWL/archive/${OPTIX_HEADERS_COMMIT}.tar.gz" \
  -o "$optix_headers_archive"
mkdir -p optix-sdk
tar -xzf "$optix_headers_archive" -C optix-sdk --strip-components=1
test -s optix-sdk/3rdParty/optix/include/optix.h
grep -q '#define OPTIX_VERSION 80000' \
  optix-sdk/3rdParty/optix/include/optix.h

write_status "configure" "Configuring the lightweight OSL, CUDA, and OptiX build."
CC=clang-18 CXX=clang++-18 cmake -S blender-src -B build -G Ninja \
  -C "$WORK_ROOT/release-config/blender-cycles-headless-rtx.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang-18 \
  -DCMAKE_CXX_COMPILER=clang++-18 \
  -DOPTIX_ROOT_DIR="$WORK_ROOT/optix-sdk/3rdParty/optix" \
  -DCMAKE_EXE_LINKER_FLAGS_INIT="-fuse-ld=lld" \
  -DCMAKE_SHARED_LINKER_FLAGS_INIT="-fuse-ld=lld"
grep -Eq '^OPTIX_INCLUDE_DIR:PATH=.*/optix-sdk/3rdParty/optix/include$' \
  build/CMakeCache.txt
grep -q '^WITH_CYCLES_DEVICE_OPTIX:BOOL=ON$' build/CMakeCache.txt
grep -q '^WITH_CYCLES_OSL:BOOL=ON$' build/CMakeCache.txt

write_status "compile" "Compiling Blender ${BLENDER_VERSION} with OSL enabled."
cmake --build build --parallel "$(nproc)"
cmake --build build --target install

stage_dir="blender-${BLENDER_VERSION}-linux-x64"
base_root="$WORK_ROOT/dist/base/$stage_dir"
mkdir -p "$base_root"
cp -a build/bin/. "$base_root/"

write_status "kernels" "Importing the official Blender ${BLENDER_VERSION} CUDA, OptiX, and OSL kernels."
official_archive="$WORK_ROOT/blender-${BLENDER_VERSION}-official.tar.xz"
curl -fsSL --retry 8 --retry-all-errors --retry-delay 3 \
  "https://download.blender.org/release/Blender${BLENDER_SERIES}/blender-${BLENDER_VERSION}-linux-x64.tar.xz" \
  -o "$official_archive"
mkdir -p official-runtime
tar -xJf "$official_archive" -C official-runtime \
  --wildcards \
  "*/${BLENDER_SERIES}/scripts/addons_core/cycles/lib/kernel_*.zst" \
  "*/${BLENDER_SERIES}/python/lib/python3.13/site-packages/attrs*" \
  "*/${BLENDER_SERIES}/python/lib/python3.13/site-packages/cattrs*"
official_kernel_dir="$(find official-runtime -type d -path "*/${BLENDER_SERIES}/scripts/addons_core/cycles/lib" | head -n 1)"
target_kernel_dir="$base_root/${BLENDER_SERIES}/scripts/addons_core/cycles/lib"
test -d "$official_kernel_dir"
mkdir -p "$target_kernel_dir"
cp -a "$official_kernel_dir"/kernel_*.zst "$target_kernel_dir/"
official_site_packages="$(find official-runtime -type d -path "*/${BLENDER_SERIES}/python/lib/python3.13/site-packages" | head -n 1)"
target_site_packages="$base_root/${BLENDER_SERIES}/python/lib/python3.13/site-packages"
test -d "$official_site_packages/cattrs"
test -d "$official_site_packages/attrs"
cp -a "$official_site_packages"/attrs* "$target_site_packages/"
cp -a "$official_site_packages"/cattrs* "$target_site_packages/"

for required_kernel in \
  kernel_compute_75.ptx.zst \
  kernel_sm_75.cubin.zst \
  kernel_sm_86.cubin.zst \
  kernel_sm_120.cubin.zst \
  kernel_optix.ptx.zst \
  kernel_optix_osl.ptx.zst \
  kernel_optix_osl_services.ptx.zst \
  kernel_optix_osl_volume.ptx.zst; do
  test -s "$target_kernel_dir/$required_kernel"
done

write_status "trim" "Trimming the base runtime while retaining NVIDIA and OSL support."
TRIM_PROFILE=farm-nvidia \
  "$WORK_ROOT/release-config/trim_blender_runtime_tree.sh" "$base_root"

mkdir -p smoke
cat >smoke/gpu_smoke.py <<'PY'
import argparse
import bpy
import json
from pathlib import Path
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--backend", required=True, choices=("CUDA", "OPTIX"))
parser.add_argument("--osl", action="store_true")
parser.add_argument("--output", required=True)
script_args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
args = parser.parse_args(script_args)

scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.device = "GPU"
scene.cycles.samples = 4
scene.render.resolution_x = 96
scene.render.resolution_y = 96
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.filepath = args.output

if args.osl:
    scene.cycles.shading_system = True

preferences = bpy.context.preferences.addons["cycles"].preferences
preferences.compute_device_type = args.backend
refresh = getattr(preferences, "refresh_devices", None)
if callable(refresh):
    refresh()
else:
    preferences.get_devices()

devices = list(preferences.devices)
selected = []
for device in devices:
    device.use = str(device.type).upper() == args.backend
    if device.use:
        selected.append(str(device.name))
if not selected:
    raise RuntimeError(f"{args.backend} enumerated zero GPU devices: {[(d.name, d.type) for d in devices]}")

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
bpy.ops.mesh.primitive_uv_sphere_add(location=(0.0, 0.0, 0.0))
sphere = bpy.context.object
material = bpy.data.materials.new("Smoke Material")
material.use_nodes = True
principled = material.node_tree.nodes.get("Principled BSDF")
principled.inputs["Base Color"].default_value = (0.13, 0.42, 0.8, 1.0)
principled.inputs["Roughness"].default_value = 0.28
sphere.data.materials.append(material)
bpy.ops.object.light_add(type="AREA", location=(3.0, -2.0, 4.0))
bpy.context.object.data.energy = 900
bpy.context.object.data.shape = "DISK"
bpy.context.object.data.size = 3.0
bpy.ops.object.camera_add(location=(3.8, -3.8, 2.7), rotation=(1.15, 0.0, 0.78))
scene.camera = bpy.context.object
bpy.ops.render.render(write_still=True)

output = Path(args.output)
if not output.is_file() or output.stat().st_size == 0:
    raise RuntimeError(f"Render output is missing: {output}")
print(
    "__RENDERBOOST_GPU_SMOKE__"
    + json.dumps(
        {
            "backend": args.backend,
            "devices": selected,
            "osl": args.osl,
            "output_bytes": output.stat().st_size,
        },
        sort_keys=True,
    ),
    flush=True,
)
PY

blender_binary="$base_root/blender"
test -x "$blender_binary"

write_status "validate-cuda" "Rendering the CUDA smoke frame on the RTX 3090."
"$blender_binary" --background --factory-startup \
  --python smoke/gpu_smoke.py -- \
  --backend CUDA \
  --output "$WORK_ROOT/smoke/cuda.png" \
  2>&1 | tee "$WORK_ROOT/smoke/cuda.log"
grep -q '__RENDERBOOST_GPU_SMOKE__' "$WORK_ROOT/smoke/cuda.log"
test -s "$WORK_ROOT/smoke/cuda.png"

write_status "validate-optix" "Rendering the OptiX smoke frame on the RTX 3090."
"$blender_binary" --background --factory-startup \
  --python smoke/gpu_smoke.py -- \
  --backend OPTIX \
  --output "$WORK_ROOT/smoke/optix.png" \
  2>&1 | tee "$WORK_ROOT/smoke/optix.log"
grep -q '__RENDERBOOST_GPU_SMOKE__' "$WORK_ROOT/smoke/optix.log"
test -s "$WORK_ROOT/smoke/optix.png"

write_status "validate-osl" "Rendering the OptiX OSL smoke frame on the RTX 3090."
"$blender_binary" --background --factory-startup \
  --python smoke/gpu_smoke.py -- \
  --backend OPTIX \
  --osl \
  --output "$WORK_ROOT/smoke/optix-osl.png" \
  2>&1 | tee "$WORK_ROOT/smoke/optix-osl.log"
grep -q '__RENDERBOOST_GPU_SMOKE__' "$WORK_ROOT/smoke/optix-osl.log"
test -s "$WORK_ROOT/smoke/optix-osl.png"

write_status "package" "Creating safe and per-SM-family runtime archives."
mkdir -p dist/work dist/artifacts

package_variant() {
  local label="$1"
  local keep_arches="$2"
  local asset_name="$3"
  local work_root="$WORK_ROOT/dist/work/$label/$stage_dir"
  mkdir -p "$work_root"
  cp -a "$base_root/." "$work_root/"
  if [[ -n "$keep_arches" ]]; then
    TRIM_PROFILE=farm-nvidia \
    TRIM_KEEP_CUDA_ARCHES="$keep_arches" \
      "$WORK_ROOT/release-config/trim_blender_runtime_tree.sh" "$work_root"
  fi
  tar -cJf "$WORK_ROOT/dist/artifacts/${asset_name}.tar.xz" \
    -C "$WORK_ROOT/dist/work/$label" "$stage_dir"
  (
    cd "$WORK_ROOT/dist/artifacts"
    sha256sum "${asset_name}.tar.xz" >"${asset_name}.tar.xz.sha256"
  )
}

package_variant safe "" "${ASSET_PREFIX}-safe"
cp "dist/artifacts/${ASSET_PREFIX}-safe.tar.xz" \
  "dist/artifacts/${ASSET_PREFIX}.tar.xz"
(
  cd "$WORK_ROOT/dist/artifacts"
  sha256sum "${ASSET_PREFIX}.tar.xz" >"${ASSET_PREFIX}.tar.xz.sha256"
)
package_variant sm75 "75" "${ASSET_PREFIX}-sm75"
package_variant sm86 "86" "${ASSET_PREFIX}-sm86"
# CUDA guarantees that an sm_86 cubin runs on sm_89. Blender 5.2 does not
# publish a distinct sm_89 cubin, so retain sm_86 plus the PTX fallback.
package_variant sm89 "86 89" "${ASSET_PREFIX}-sm89"
package_variant sm120 "120" "${ASSET_PREFIX}-sm120"

ASSET_PREFIX="$ASSET_PREFIX" RELEASE_LABEL="$RELEASE_LABEL" \
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

root = Path("dist/artifacts")
manifest = {
    "release": os.environ["RELEASE_LABEL"],
    "assets": {},
}
for path in sorted(root.glob("*.tar.xz")):
    manifest["assets"][path.name] = {
        "bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }
(root / "release-assets.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

cp smoke/*.png dist/artifacts/
cp "$LOG_PATH" dist/artifacts/build.log
tar -cf "$WORK_ROOT/${RELEASE_LABEL}-results.tar" -C dist/artifacts .

write_status "upload" "Uploading completed runtime artifacts for GitHub publication."
upload_file "$WORK_ROOT/${RELEASE_LABEL}-results.tar" "$RESULT_PUT_URL"
