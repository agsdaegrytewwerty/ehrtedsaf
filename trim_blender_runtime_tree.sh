#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[trim-blender-runtime] %s\n' "$*" >&2
}

cleanup_copyfile_artifacts() {
  local root="${1:-}"
  [[ -d "$root" ]] || return 0
  find "$root" -depth \( -name '__MACOSX' -o -name '.DS_Store' -o -name '._*' \) -exec rm -rf {} + 2>/dev/null || true
}

usage() {
  cat >&2 <<'EOF'
Usage: trim_blender_runtime_tree.sh /path/to/blender-runtime-root

Trim a Blender runtime tree in place for RenderBoost.io's headless Cycles farm
use case. This removes build-only Python artifacts plus UI/localization assets
that are not needed to render already-authored .blend files in background mode.
EOF
  exit 1
}

remove_path() {
  local target
  for target in "$@"; do
    if [[ -e "$target" || -L "$target" ]]; then
      rm -rf "$target"
      log "Removed $target"
    fi
  done
}

remove_glob() {
  local pattern="$1"
  local expanded=()
  shopt -s nullglob
  expanded=($pattern)
  shopt -u nullglob
  if (( ${#expanded[@]} > 0 )); then
    remove_path "${expanded[@]}"
  fi
}

series_from_root() {
  local root="$1"
  if [[ -n "${BLENDER_RELEASE_SERIES:-}" ]]; then
    printf '%s\n' "${BLENDER_RELEASE_SERIES}"
    return 0
  fi

  local found=()
  while IFS= read -r dir; do
    found+=("$dir")
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | rg '^[0-9]+\.[0-9]+$' | sort)

  if (( ${#found[@]} == 1 )); then
    printf '%s\n' "${found[0]}"
    return 0
  fi

  log "Could not uniquely detect Blender series under $root"
  if (( ${#found[@]} > 0 )); then
    log "Candidate series dirs: ${found[*]}"
  fi
  return 1
}

prune_cycles_kernels_for_release_family() {
  local runtime_root="${1:-}"
  local series="${2:-}"
  local keep_arches_raw="${3:-}"
  [[ -d "$runtime_root" && -n "$series" && -n "$keep_arches_raw" ]] || return 0

  local kernel_dir="$runtime_root/$series/scripts/addons_core/cycles/lib"
  [[ -d "$kernel_dir" ]] || return 0

  BLENDER_KERNEL_DIR="$kernel_dir" BLENDER_KEEP_ARCHES="$keep_arches_raw" python3 - <<'PY'
from pathlib import Path
import os
import re

kernel_dir = Path(os.environ["BLENDER_KERNEL_DIR"])
arches = []
for match in re.findall(r"\d{2,3}", os.environ.get("BLENDER_KEEP_ARCHES", "")):
    value = str(int(match))
    if value not in arches:
        arches.append(value)

if not arches:
    raise SystemExit(0)

keep = {path.name for path in kernel_dir.glob("kernel_optix*.zst") if path.is_file()}
for arch in arches:
    cubin = kernel_dir / f"kernel_sm_{arch}.cubin.zst"
    if cubin.is_file():
        keep.add(cubin.name)

compute_files = sorted(path for path in kernel_dir.glob("kernel_compute_*.ptx.zst") if path.is_file())
for arch in arches:
    compute = kernel_dir / f"kernel_compute_{arch}.ptx.zst"
    if compute.is_file():
        keep.add(compute.name)
if not any(name.startswith("kernel_compute_") for name in keep) and compute_files:
    def compute_key(path: Path):
        match = re.search(r"kernel_compute_(\d+)\.ptx\.zst$", path.name)
        return int(match.group(1)) if match else 0
    fallback = sorted(compute_files, key=compute_key)[0]
    keep.add(fallback.name)

for path in kernel_dir.glob("kernel_sm_*.cubin.zst"):
    if path.name not in keep:
        path.unlink(missing_ok=True)
for path in compute_files:
    if path.name not in keep:
        path.unlink(missing_ok=True)

print(
    "Kept release-family Cycles kernels: "
    + ", ".join(sorted(keep))
    + f" (requested arches: {', '.join(arches)})"
)
PY
}

main() {
  [[ $# -eq 1 ]] || usage

  local root="$1"
  [[ -d "$root" ]] || {
    log "Runtime root not found: $root"
    exit 1
  }
  root="$(cd "$root" && pwd)"

  local before_size
  before_size="$(du -sh "$root" | awk '{print $1}')"
  cleanup_copyfile_artifacts "$root"

  local series
  series="$(series_from_root "$root")"
  local series_dir="$root/$series"
  [[ -d "$series_dir" ]] || {
    log "Series directory not found: $series_dir"
    exit 1
  }

  local python_base
  python_base="$(find "$series_dir/python/lib" -mindepth 1 -maxdepth 1 -type d -name 'python3.*' | sort | head -n 1 || true)"
  if [[ -z "$python_base" ]]; then
    log "Embedded Python runtime not found under $series_dir/python/lib"
    exit 1
  fi
  local site_packages="$python_base/site-packages"
  local profile="${TRIM_PROFILE:-safe}"

  log "Trimming Blender runtime at $root (series $series, profile $profile)"

  remove_path \
    "$root/blender-launcher" \
    "$root/blender-softwaregl" \
    "$root/blender-thumbnailer" \
    "$root/blender.desktop" \
    "$root/blender.svg" \
    "$root/blender-symbolic.svg" \
    "$root/blender-system-info.sh" \
    "$root/datatoc" \
    "$root/makesdna" \
    "$root/makesrna" \
    "$root/shader_tool" \
    "$root/zstd_compress" \
    "$root/readme.html"

  remove_path \
    "$series_dir/scripts/templates_py" \
    "$series_dir/scripts/templates_osl" \
    "$series_dir/scripts/templates_toml" \
    "$series_dir/scripts/presets" \
    "$series_dir/scripts/startup/bl_app_templates_system" \
    "$series_dir/scripts/addons_core/cycles/source" \
    "$series_dir/datafiles/locale" \
    "$series_dir/datafiles/icons" \
    "$series_dir/datafiles/studiolights" \
    "$series_dir/datafiles/assets" \
    "$series_dir/python/bin" \
    "$python_base/ensurepip" \
    "$site_packages/pip" \
    "$site_packages/setuptools" \
    "$site_packages/pkg_resources" \
    "$site_packages/_distutils_hack" \
    "$site_packages/Cython" \
    "$site_packages/pyximport" \
    "$site_packages/distutils-precedence.pth"

  remove_glob "$series_dir/python/lib/libpython*.a"
  remove_glob "$python_base/config-*"
  remove_glob "$site_packages/pip-*.dist-info"
  remove_glob "$site_packages/setuptools-*.dist-info"
  remove_glob "$site_packages/Cython-*.egg-info"
  remove_glob "$site_packages/autopep8-*.dist-info"
  remove_glob "$site_packages/pycodestyle-*.dist-info"

  remove_path \
    "$site_packages/cython.py" \
    "$site_packages/autopep8.py" \
    "$site_packages/pycodestyle.py"

  if [[ "$profile" == "farm-nvidia" ]]; then
    remove_path \
      "$site_packages/pxr" \
      "$site_packages/MaterialX" \
      "$site_packages/OpenImageIO" \
      "$site_packages/PyOpenColorIO" \
      "$root/lib/mesa" \
      "$root/lib/libhiprt64.so"

    remove_glob "$site_packages/openvdb.cpython-*.so"
    remove_glob "$site_packages/MaterialX-*.dist-info"
    remove_glob "$site_packages/OpenImageIO-*.dist-info"
    remove_glob "$site_packages/PyOpenColorIO-*.dist-info"
    remove_glob "$site_packages/usd_core-*.dist-info"
    remove_glob "$root/lib/libOpenImageDenoise_device_hip.so.*"
    remove_glob "$root/lib/libvulkan.so*"
    remove_glob "$series_dir/scripts/addons_core/cycles/lib/kernel_gfx*.zst"
    remove_glob "$series_dir/scripts/addons_core/cycles/lib/kernel_rt_gfx*.zst"

    local keep_cuda_arches="${TRIM_KEEP_CUDA_ARCHES:-}"
    prune_cycles_kernels_for_release_family "$root" "$series" "$keep_cuda_arches"
  fi

  local after_size
  cleanup_copyfile_artifacts "$root"
  after_size="$(du -sh "$root" | awk '{print $1}')"
  log "Trim complete: $before_size -> $after_size"
}

main "$@"
