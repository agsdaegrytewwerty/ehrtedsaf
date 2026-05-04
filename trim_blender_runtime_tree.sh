#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[trim-blender-runtime] %s\n' "$*" >&2
}

usage() {
  cat >&2 <<'EOF'
Usage: trim_blender_runtime_tree.sh /path/to/blender-runtime-root

Trim a Blender runtime tree in place for YesterdayRender's headless Cycles farm
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
  local series_pattern='^[0-9]+\.[0-9]+$'
  while IFS= read -r dir; do
    found+=("$dir")
  done < <(
    find "$root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \
      | { if command -v rg >/dev/null 2>&1; then rg "$series_pattern"; else grep -E "$series_pattern"; fi; } \
      | sort
  )

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
      "$root/lib/libhiprt64.so" \
      "$root/lib/libcycles_kernel_oneapi_aot.so"

    remove_glob "$site_packages/openvdb.cpython-*.so"
    remove_glob "$site_packages/MaterialX-*.dist-info"
    remove_glob "$site_packages/OpenImageIO-*.dist-info"
    remove_glob "$site_packages/PyOpenColorIO-*.dist-info"
    remove_glob "$site_packages/usd_core-*.dist-info"
    remove_glob "$root/lib/libMaterialX*.so*"
    remove_glob "$root/lib/libusd_ms.so*"
    remove_glob "$root/lib/libOpenImageDenoise_device_hip.so.*"
    remove_glob "$root/lib/libOpenImageDenoise_device_sycl.so.*"
    remove_glob "$root/lib/libsycl.so*"
    remove_glob "$root/lib/libur_adapter_level_zero.so*"
    remove_glob "$root/lib/libur_loader.so*"
    remove_glob "$root/lib/libvulkan.so*"
    remove_glob "$series_dir/scripts/addons_core/cycles/lib/kernel_gfx*.zst"
    remove_glob "$series_dir/scripts/addons_core/cycles/lib/kernel_rt_gfx*.zst"

    local keep_cuda_arches="${TRIM_KEEP_CUDA_ARCHES:-}"
    if [[ -n "$keep_cuda_arches" ]]; then
      local normalized_keep=",$(printf '%s' "$keep_cuda_arches" | tr -d ' '),"
      normalized_keep="${normalized_keep//,,/,}"
      local cubin base arch
      while IFS= read -r cubin; do
        base="$(basename "$cubin")"
        arch="${base#kernel_sm_}"
        arch="${arch%.cubin.zst}"
        if [[ "$normalized_keep" != *",$arch,"* ]]; then
          remove_path "$cubin"
        fi
      done < <(find "$series_dir/scripts/addons_core/cycles/lib" -maxdepth 1 -type f -name 'kernel_sm_*.cubin.zst' | sort)
    fi
  fi

  local after_size
  after_size="$(du -sh "$root" | awk '{print $1}')"
  log "Trim complete: $before_size -> $after_size"
}

main "$@"
