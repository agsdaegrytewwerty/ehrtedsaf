#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[verify-blender-runtime] %s\n' "$*" >&2
}

usage() {
  cat >&2 <<'EOF'
Usage: verify_blender_runtime_tree.sh /path/to/blender-runtime-root

Verify that the NVIDIA farm runtime retains its rendering libraries while no
ELF file or symlink ships or requires a dependency pruned by the farm profile.
EOF
  exit 1
}

is_forbidden_library() {
  local name="${1##*/}"
  case "$name" in
    libusd_ms.so* | \
    libMaterialX*.so* | \
    libembree*.so* | \
    libsycl.so* | \
    libur_*.so* | \
    libOpenImageDenoise_device_sycl.so* | \
    libOpenImageDenoise_device_hip.so* | \
    libSDL3.so* | \
    libdraco*.so* | \
    libhiprt*.so* | \
    libvulkan.so*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

require_glob() {
  local pattern="$1"
  if ! compgen -G "$pattern" >/dev/null; then
    log "Required runtime payload is missing: $pattern"
    return 1
  fi
}

list_needed_libraries() {
  local elf_file="$1"
  local dynamic_section

  if [[ "$elf_inspector" == "readelf" ]]; then
    dynamic_section="$(readelf -d "$elf_file" 2>/dev/null || true)"
    awk '
      /\(NEEDED\)/ {
        if (match($0, /\[[^]]+\]/)) {
          print substr($0, RSTART + 1, RLENGTH - 2)
        }
      }
    ' <<<"$dynamic_section"
  else
    dynamic_section="$(objdump -p "$elf_file" 2>/dev/null || true)"
    awk '$1 == "NEEDED" {print $2}' <<<"$dynamic_section"
  fi
}

main() {
  [[ $# -eq 1 ]] || usage

  local root="$1"
  [[ -d "$root" ]] || {
    log "Runtime root not found: $root"
    exit 1
  }
  root="$(cd "$root" && pwd)"

  [[ -x "$root/blender" ]] || {
    log "Blender executable is missing or not executable: $root/blender"
    exit 1
  }

  local required_pattern
  for required_pattern in \
    "$root/lib/libOpenImageDenoise.so*" \
    "$root/lib/libOpenImageDenoise_device_cpu.so*" \
    "$root/lib/libOpenImageDenoise_device_cuda.so*" \
    "$root/lib/libOpenImageIO.so*" \
    "$root/lib/libOpenColorIO.so*" \
    "$root/lib/libopenvdb.so*" \
    "$root/lib/liboslexec.so*"; do
    require_glob "$required_pattern"
  done

  local violations=0
  local forbidden_pattern
  local forbidden_patterns=(
    "$root/lib/libusd_ms.so*"
    "$root/lib/libMaterialX*.so*"
    "$root/lib/libembree*.so*"
    "$root/lib/libsycl.so*"
    "$root/lib/libur_*.so*"
    "$root/lib/libOpenImageDenoise_device_sycl.so*"
    "$root/lib/libOpenImageDenoise_device_hip.so*"
    "$root/lib/libSDL3.so*"
    "$root/lib/libdraco*.so*"
    "$root/lib/libhiprt*.so*"
    "$root/lib/libvulkan.so*"
    "$root/lib/mesa"
    "$root/[0-9]*.[0-9]*/python/lib/python*/site-packages/pxr"
    "$root/[0-9]*.[0-9]*/python/lib/python*/site-packages/MaterialX"
    "$root/[0-9]*.[0-9]*/python/lib/python*/site-packages/MaterialX-*.dist-info"
    "$root/[0-9]*.[0-9]*/python/lib/python*/site-packages/OpenImageIO"
    "$root/[0-9]*.[0-9]*/python/lib/python*/site-packages/OpenImageIO-*.dist-info"
    "$root/[0-9]*.[0-9]*/python/lib/python*/site-packages/PyOpenColorIO"
    "$root/[0-9]*.[0-9]*/python/lib/python*/site-packages/PyOpenColorIO-*.dist-info"
    "$root/[0-9]*.[0-9]*/python/lib/python*/site-packages/openvdb.cpython-*.so"
    "$root/[0-9]*.[0-9]*/python/lib/python*/site-packages/usd_core-*.dist-info"
  )
  local path
  for forbidden_pattern in "${forbidden_patterns[@]}"; do
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      log "Forbidden dependency payload remains: ${path#$root/}"
      violations=$((violations + 1))
    done < <(compgen -G "$forbidden_pattern" || true)
  done

  local elf_inspector
  if command -v readelf >/dev/null 2>&1; then
    elf_inspector="readelf"
  elif command -v objdump >/dev/null 2>&1; then
    elf_inspector="objdump"
  else
    log "Neither readelf nor objdump is available for ELF dependency checks"
    exit 1
  fi

  local elf_count=0
  local magic
  local needed
  while IFS= read -r -d '' path; do
    magic="$(od -An -tx1 -N4 "$path" 2>/dev/null | tr -d ' \n')"
    [[ "$magic" == "7f454c46" ]] || continue
    elf_count=$((elf_count + 1))

    while IFS= read -r needed; do
      [[ -n "$needed" ]] || continue
      if is_forbidden_library "$needed"; then
        log "Retained ELF ${path#$root/} requires forbidden library $needed"
        violations=$((violations + 1))
      fi
    done < <(list_needed_libraries "$path")
  done < <(
    find "$root" -type f \
      \( -perm -111 -o -name '*.so' -o -name '*.so.*' \) \
      -print0
  )

  if (( elf_count == 0 )); then
    log "No ELF files found under runtime root"
    exit 1
  fi
  if (( violations > 0 )); then
    log "Runtime verification failed with $violations violation(s)"
    exit 1
  fi

  log "Verified $elf_count ELF files; retained render dependencies are present and the pruned dependency closure is clean"
}

main "$@"
